const std = @import("std");
const Io = std.Io;

const chap_rast = @import("chap_rast");

const I32Op = union(enum) {
    set: i32,

    const Self = @This();

    pub fn apply(self: Self, data: *i32) void {
        switch (self) {
            .set => |val| data.* = val,
        }
    }
    pub fn default() Self {
        return .{ .set = 0 };
    }
};

pub fn main(_: std.process.Init) !void {
    const cr = chap_rast.ChapRast(i32, I32Op, .yield_on_wait).initWithDefault(std.heap.page_allocator, 0, 1) catch |err| {
        std.debug.print("Error initializing ChapRast: {any}\n", .{err});
        return err;
    };
    std.debug.print("cr {any}", .{cr});
}
