const std = @import("std");
const atomic = std.atomic;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const Thread = std.Thread;
const CachePadded = @import("cache_padded.zig").CachePadded;

pub const Yield = enum {
    yield_on_wait,
    no_yield,
};

pub fn ChapRast(comptime T: type, comptime O: type, comptime yield_on_wait: Yield) type {
    comptime if (!meta.hasFn(O, "apply"))
        @compileError(@typeName(O) ++
            " does not implement the `apply` method");

    return struct {
        // ChapRast takes ownership of the datatype being paseed to it.
        left: T,
        right: T,

        // we assume that the left copy is the one that being read
        read_left: atomic.Value(u8),

        // each reader writes to its owned cache-line; so there is no
        // coordinations according to MESI protocol
        readers_lock: []CachePadded(atomic.Value(bool)),

        // all readers read a single, shared write lock, but since
        // writes are occasional, this will be in "Shared" state according
        // to MESI protocol. the only cost is for reader registeration time.
        write_lock: atomic.Value(bool),

        logs: std.ArrayListUnmanaged(O),
        gpa: mem.Allocator,

        const Self = @This();

        pub fn init(gpa: mem.Allocator, max_readers: usize) !Self {
            comptime if (!meta.hasFn(T, "default"))
                @compileError(@typeName(T) ++
                    " does not implement the `default` method");

            const readers_lock = try gpa.alloc(
                CachePadded(atomic.Value(bool)),
                max_readers,
            );
            errdefer gpa.free(readers_lock);
            for (readers_lock) |*rl| rl.* = .init(.init(false));

            const logs = try std.ArrayListUnmanaged(O).initCapacity(gpa, 8);
            errdefer logs.deinit(gpa);

            return Self{
                .left = T.default(),
                .right = T.default(),
                .read_left = .init(1),
                .readers_lock = readers_lock,
                .write_lock = .init(.init(false)),
                .logs = logs,
                .gpa = gpa,
            };
        }

        pub fn initWithDefault(gpa: mem.Allocator, val: T, max_readers: usize) !Self {
            const readers_lock = try gpa.alloc(
                CachePadded(atomic.Value(bool)),
                max_readers,
            );
            for (readers_lock) |*rl| rl.* = .init(.init(false));

            const logs = try std.ArrayListUnmanaged(O).initCapacity(gpa, 8);
            errdefer logs.deinit(gpa);

            return Self{
                .left = val,
                .right = val,
                .read_left = .init(1),
                .readers_lock = readers_lock,
                .write_lock = .init(false),
                .logs = logs,
                .gpa = gpa,
            };
        }

        pub fn deinit(self: *Self) void {
            self.gpa.free(self.readers_lock);
            self.logs.deinit(self.gpa);
        }

        pub fn lock(self: *Self, idx: usize) *const T {
            while (self.write_lock.load(.acquire)) {
                if (comptime yield_on_wait == .yield_on_wait)
                    Thread.yield();
            }
            self.readers_lock[idx].mut().store(true, .release);
            return if (self.read_left.load(.unordered) == 1) &self.left else &self.right;
        }

        pub fn unlock(self: *Self, idx: usize) void {
            self.readers_lock[idx].mut().store(false, .release);
        }

        pub fn wpointer(self: *const Self) *const T {
            return if (self.read_left.load(.unordered) == 1) &self.right else &self.left;
        }

        pub fn apply(self: *Self, op: O) !void {
            const p = if (self.read_left.load(.unordered) == 1) &self.right else &self.left;
            try self.logs.append(self.gpa, op);
            op.apply(p);
        }

        // publish is not thread-safe: only one publish at a time
        pub fn publish(self: *Self) void {
            self.write_lock.store(true, .release);
            defer self.write_lock.store(false, .release);
            guard: while (true) {
                for (self.readers_lock) |rl| {
                    if (rl.ref().load(.acquire)) continue :guard;
                }
                break;
            }
            self.publishAssumeNoReader();
        }

        // tryPublish is not thread-safe: only one tryPublish at a time
        pub fn tryPublish(self: *Self) bool {
            self.write_lock.store(true, .release);
            defer self.write_lock.store(false, .release);
            for (self.readers_lock) |rl| {
                if (rl.ref().load(.acquire)) return false;
            }
            self.publishAssumeNoReader();
            return true;
        }

        fn publishAssumeNoReader(self: *Self) void {
            // flip pointer and write data
            const dst = if (self.read_left.bitToggle(0, .acquire) == 1) &self.left else &self.right;
            for (self.logs.items) |op| op.apply(dst);
            self.logs.clearRetainingCapacity();
        }
    };
}

test "multi reader" {
    const alloc = testing.allocator;

    const I32Op = union(enum) {
        set: i32,
        pub fn apply(self: @This(), data: *i32) void {
            switch (self) {
                .set => |val| data.* = val,
            }
        }
    };

    for (0..64) |_| {
        var chaprast = try ChapRast(i32, I32Op, .no_yield).initWithDefault(alloc, 0, 16);
        defer chaprast.deinit();

        const ErrorCount = atomic.Value(u16);
        var errors: ErrorCount = .init(0);

        const Reader = struct {
            fn start(
                cr: *ChapRast(i32, I32Op, .no_yield),
                idx: usize,
                err_count: *ErrorCount,
            ) void {
                var state0: bool = true;

                for (0..10 * 1000) |_| {
                    const data = cr.lock(idx);
                    defer cr.unlock(idx);
                    // perform some computation in critical zone
                    // ...
                    if (state0) {
                        if (data.* != 0x00 and data.* != 0x8088) {
                            _ = err_count.fetchAdd(1, .acq_rel);
                            return;
                        }
                        if (data.* == 0x8088) {
                            state0 = false;
                        }
                    } else {
                        if (data.* != 0x8088) {
                            _ = err_count.fetchAdd(1, .acq_rel);
                            return;
                        }
                    }
                }
            }
        };

        var handles: [16]Thread = undefined;
        for (handles, 0..) |_, idx|
            handles[idx] = try Thread.spawn(
                .{},
                Reader.start,
                .{ &chaprast, idx, &errors },
            );

        try chaprast.apply(.{ .set = 0x8088 });
        chaprast.publish();

        for (handles) |h| h.join();
        try testing.expectEqual(0, errors.load(.acquire));
    }
}
