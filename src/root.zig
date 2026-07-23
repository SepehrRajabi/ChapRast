//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const ReadHandler = struct {
    // epochs
    // epoch_number / iteration
    // reference to the parent struct for reading the data
    // is_locked: atomic bool false aligned 64
};

pub const WriteHandler = struct {};

pub fn ChapRast(comptime T: type) type {
    // ChapRast takes ownership of the datatype being paseed to it.
    return struct {
        left: T,
        right: T,
        write_handler: WriteHandler,
        read_handler: ReadHandler,
        // we assume that the left copy is the one that being read
        is_left: std.atomic.Value(bool),
        // pointer: std.atomic.Value(*T),

        const Self = @This();
        const AtomicBool = std.atomic.Value(true);

        pub fn init() !Self {
            if (!(@hasDecl(T, "default"))) {
                @compileError("ChapRast does not implement the `default` method");
            }

            const left = T.default();
            const right = T.default();

            return Self{
                .left = left,
                .right = right,
                .write_handler = WriteHandler{},
                .read_handler = ReadHandler{},
                .is_left = AtomicBool.init(true),
                // .pointer = AtomicPointer.init(&left),
            };
        }

        pub fn initWithDefault(val: T) !Self {
            return Self{
                .left = val,
                .right = val,
                .write_handler = WriteHandler{},
                .read_handler = ReadHandler{},
                .is_left = std.atomic.Value(bool).init(true),
                // .pointer = AtomicPointer.init(&left),
            };
        }
    };
}
