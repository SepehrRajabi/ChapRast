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

pub fn ChapRast(comptime T: type, comptime yield_on_wait: Yield) type {
    return struct {
        // ChapRast takes ownership of the datatype being paseed to it.
        left: T,
        right: T,

        // we assume that the left copy is the one that being read
        read_left: atomic.Value(bool),

        // each reader writes to its owned cache-line; so there is no
        // coordinations according to MESI protocol
        readers_lock: []CachePadded(atomic.Value(bool)),

        // all readers read a single, shared write lock, but since
        // writes are occasional, this will be in "Shared" state according
        // to MESI protocol. the only cost is for reader registeration time.
        write_lock: atomic.Value(bool),

        gpa: mem.Allocator,

        const Self = @This();

        pub fn init(gpa: mem.Allocator, max_readers: usize) !Self {
            if (!meta.hasFn(T, "default"))
                @compileError(@typeName(T) ++
                    " does not implement the `default` method");

            const readers_lock = try gpa.alloc(
                CachePadded(atomic.Value(bool)),
                max_readers,
            );
            for (readers_lock) |*rl| rl.* = .init(.init(false));

            return Self{
                .left = T.default(),
                .right = T.default(),
                .read_left = .init(true),
                .readers_lock = readers_lock,
                .write_lock = .init(.init(false)),
                .gpa = gpa,
            };
        }

        pub fn initWithDefault(gpa: mem.Allocator, val: T, max_readers: usize) !Self {
            const readers_lock = try gpa.alloc(
                CachePadded(atomic.Value(bool)),
                max_readers,
            );
            for (readers_lock) |*rl| rl.* = .init(.init(false));

            return Self{
                .left = val,
                .right = val,
                .read_left = .init(true),
                .readers_lock = readers_lock,
                .write_lock = .init(false),
                .gpa = gpa,
            };
        }

        pub fn deinit(self: *Self) void {
            self.gpa.free(self.readers_lock);
        }

        pub fn lock(self: *Self, idx: usize) *const T {
            while (self.write_lock.load(.acquire)) {
                if (comptime yield_on_wait == .yield_on_wait)
                    Thread.yield();
            }
            self.readers_lock[idx].mut().store(true, .release);
            return if (self.read_left.load(.unordered)) &self.left else &self.right;
        }

        pub fn unlock(self: *Self, idx: usize) void {
            self.readers_lock[idx].mut().store(false, .release);
        }

        pub fn wpointer(self: *const Self) *T {
            return if (self.read_left.load(.unordered)) &self.right else &self.left;
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
            // copy data: for now just shallow copy.
            // we have to store logs and reapply logs.
            const src, const dst = if (self.read_left.load(.unordered))
                .{ &self.left, &self.right }
            else
                .{ &self.right, &self.left };
            dst.* = src.*;

            // flip pointer
            self.read_left.fetchXor(true, .unordered);
        }
    };
}

test "multi reader" {
    const alloc = testing.allocator;
    var chaprast = try ChapRast(i32, .no_yield).initWithDefault(alloc, 0x8088, 16);
    defer chaprast.deinit();

    const ErrorCount = atomic.Value(u16);
    var errors: ErrorCount = .init(0);

    const Reader = struct {
        fn start(
            cr: *ChapRast(i32, .no_yield),
            idx: usize,
            err_count: *ErrorCount,
        ) void {
            for (0..10 * 1000) |_| {
                const data = cr.lock(idx);
                defer cr.unlock(idx);
                // perform some computation in critical zone
                // ...
                if (data.* != 0x8088) {
                    _ = err_count.fetchAdd(1, .acq_rel);
                    return;
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
    for (handles) |h| h.join();
    try testing.expectEqual(0, errors.load(.acquire));
}
