const std = @import("std");
const atomic = std.atomic;
const mem = std.mem;
const meta = std.meta;

pub fn ChapRast(comptime T: type) type {
    return struct {
        // ChapRast takes ownership of the datatype being paseed to it.
        left: T,
        right: T,
        // we assume that the left copy is the one that being read
        read_left: AtomicBool,
        readers_lock: []atomic.Value(CachePaddedBool),

        const Self = @This();

        pub fn init() !Self {
            if (!meta.hasFn(T, "default"))
                @compileError(@typeName(T) ++
                    " does not implement the `default` method");

            return Self{
                .left = T.default(),
                .right = T.default(),
                .read_left = AtomicBool.init(true),
            };
        }

        pub fn initWithDefault(val: T) !Self {
            return Self{
                .left = val,
                .right = val,
                .read_left = std.atomic.Value(bool).init(true),
            };
        }

        pub fn lock(self: *Self, idx: usize) *const T {
            self.readers_lock[idx].store(CachePaddedBool.init(true), .release);
            return self.pointer();
        }

        pub fn unlock(self: *Self, idx: usize) void {
            self.readers_lock[idx].store(CachePaddedBool.init(false), .release);
        }

        pub fn pointer(self: *const Self) *const T {
            return if (self.read_left.load(.unordered)) &self.left else &self.right;
        }
    };
}

const AtomicBool = std.atomic.Value(bool);
const CachePaddedBool = CachePadded(bool);

fn CachePadded(comptime T: type) type {
    return struct {
        inner: T align(64),

        pub fn init(v: T) @This() {
            return .{ .inner = v };
        }

        pub fn store(self: *@This(), v: T) void {
            self.*.inner = v;
        }

        pub fn load(self: *const @This()) T {
            return self.*.inner;
        }
    };
}

test "first test" {
    // nop
}
