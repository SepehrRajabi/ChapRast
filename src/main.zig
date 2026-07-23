const std = @import("std");
const Io = std.Io;

const chap_rast = @import("chap_rast");

pub fn main(_: std.process.Init) !void {
    const cr = chap_rast.ChapRast(i32).initWithDefault(0) catch |err| {
        std.debug.print("Error initializing ChapRast: {any}\n", .{err});
        return err;
    };
    std.debug.print("cr {any}", .{cr});
}
