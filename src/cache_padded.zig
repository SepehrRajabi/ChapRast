pub fn CachePadded(comptime T: type) type {
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
