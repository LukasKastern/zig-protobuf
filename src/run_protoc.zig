const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena);

    // Skip executable
    _ = args.next();

    const protoc = args.next() orelse return error.ProtocMissing;
    const protoc_gen_zig = args.next() orelse return error.ProtocGenMissing;
    const src_file = args.next() orelse return error.SourceFileMissing;
    const out_file = args.next() orelse return error.OutputFileMissing;

    // Rest are include directories
    var include_directories: std.ArrayList([]const u8) = .empty;
    while (args.next()) |include| {
        try include_directories.append(init.arena.allocator(), include);
    }
}
