const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());

    _ = args.next();

    const dir = args.next() orelse return error.FileNotGiven;

    const dir_handle = try std.Io.Dir.cwd().createDirPathOpen(init.io, dir, .{});
    _ = try dir_handle.createFile(init.io, "api.zig", .{});
}
