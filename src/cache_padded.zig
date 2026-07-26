const std = @import("std");
const atomic = std.atomic;
const testing = std.testing;

pub fn CachePadded(comptime T: type) type {
    return extern struct {
        inner: T align(64),

        const Self = @This();
        pub fn init(v: T) Self {
            return .{ .inner = v };
        }
        pub fn ref(self: *const Self) *align(64) const T {
            return &self.inner;
        }
        pub fn mut(self: *Self) *align(64) T {
            return &self.inner;
        }
    };
}

test "basic CachePadded usage" {
    inline for ([_]type{ i8, i16, i32, i64 }) |T| {
        const CP = CachePadded(T);
        try testing.expect(@alignOf(CP) == 64);

        var x = CP.init(0x00);
        try testing.expectEqual(@as(T, 0x00), x.ref().*);

        x.mut().* = 0x10;
        try testing.expectEqual(@as(T, 0x10), x.ref().*);
    }
}

test "CachePadded atomic " {
    var x = CachePadded(atomic.Value(i16))
        .init(.init(0x00));
    try testing.expectEqual(0x00, x.ref().load(.acquire));
    x.mut().store(0x10, .release);
    try testing.expectEqual(0x10, x.ref().load(.acquire));
}
