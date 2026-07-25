const std = @import("std");
const atomic = std.atomic;
const mem = std.mem;
const meta = std.meta;
const testing = std.testing;
const Thread = std.Thread;
const CachePadded = @import("cache_padded.zig");

pub fn ChapRast(comptime T: type) type {
    return struct {
        // ChapRast takes ownership of the datatype being paseed to it.
        left: T,
        right: T,
        // we assume that the left copy is the one that being read
        read_left: atomic.Value(bool),
        // each reader writes to its owned cache-line; so there is no
        // coordinations according to MESI protocol
        readers_lock: []atomic.Value(CachePadded(bool)),
        // all readers read a single, shared write lock, but since
        // writes are occasional, this will be in "Shared" state according
        // to MESI protocol. the only cost is for reader registeration time.
        write_lock: atomic.Value(CachePadded(bool)),

        alloc: mem.Allocator,

        const Self = @This();

        pub fn init(alloc: mem.Allocator, max_readers: usize) !Self {
            if (!meta.hasFn(T, "default"))
                @compileError(@typeName(T) ++
                    " does not implement the `default` method");

            const readers_lock = try alloc.alloc(atomic.Value(CachePadded(bool)), max_readers);
            for (readers_lock) |*rl| rl.* = .init(.init(false));

            return Self{
                .left = T.default(),
                .right = T.default(),
                .read_left = .init(true),
                .readers_lock = readers_lock,
                .write_lock = .init(.init(false)),
                .alloc = alloc,
            };
        }

        pub fn initWithDefault(alloc: mem.Allocator, val: T, max_readers: usize) !Self {
            const readers_lock = try alloc.alloc(atomic.Value(CachePadded(bool)), max_readers);
            for (readers_lock) |*rl| rl.* = .init(.init(false));

            return Self{
                .left = val,
                .right = val,
                .read_left = .init(true),
                .readers_lock = readers_lock,
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            self.alloc.free(self.readers_lock);
        }

        pub fn lock(self: *Self, idx: usize) *const T {
            while (self.write_lock.load(.acquire)) {
                // maybe Thread.yield() here?
            }
            self.readers_lock[idx].store(.init(true), .release);
            return self.pointer();
        }

        pub fn unlock(self: *Self, idx: usize) void {
            self.readers_lock[idx].store(.init(false), .release);
        }

        pub fn pointer(self: *const Self) *const T {
            return if (self.read_left.load(.unordered)) &self.left else &self.right;
        }

        pub fn wlock(self: *Self) void {
            self.write_lock.store(.init(true), .release);
            outer: while (true) {
                for (self.readers_lock) |rl| {
                    if (rl.load(.acquire)) continue :outer;
                }
                break;
            }
        }

        pub fn wunlock(self: *Self) void {
            self.write_lock.store(.init(false), .release);
        }

        pub fn wpointer(self: *const Self) *T {
            return if (self.read_left.load(.unordered)) &self.right else &self.left;
        }
    };
}

test "first test" {
    // nop
}
