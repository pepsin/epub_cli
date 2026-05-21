const std = @import("std");
const Epub = @import("epub.zig").Epub;
const Repl = @import("repl.zig").Repl;
const Config = @import("config.zig").Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("\x1b[1;31mUsage: {s} <epub-file>\x1b[0m\n", .{args[0]});
        try stderr.print("\n", .{});
        try stderr.print("\x1b[1;33mAn interactive EPUB reader for the terminal.\x1b[0m\n", .{});
        try stderr.print("\n", .{});
        try stderr.print("Examples:\n", .{});
        try stderr.print("  {s} book.epub       Open and read a book\n", .{args[0]});
        try stderr.print("\n", .{});
        std.process.exit(1);
    }

    const file_path = args[1];

    // Check if file exists
    std.fs.cwd().access(file_path, .{}) catch {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("\x1b[1;31mError: Cannot open file '{s}'\x1b[0m\n", .{file_path});
        std.process.exit(1);
    };

    // Resolve absolute path for stable config keys
    const file_path_abs = std.fs.cwd().realpathAlloc(allocator, file_path) catch |err| blk: {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("\x1b[1;33mWarning: could not resolve full path ({s}), using '{s}'\x1b[0m\n", .{ @errorName(err), file_path });
        break :blk try allocator.dupe(u8, file_path);
    };
    defer allocator.free(file_path_abs);

    // Load config
    var config_loaded = false;
    var config: Config = undefined;
    if (Config.init(allocator)) |cfg| {
        config = cfg;
        config_loaded = true;
    } else |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("\x1b[1;33mWarning: config unavailable ({s})\x1b[0m\n", .{@errorName(err)});
    }
    defer if (config_loaded) config.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print("\x1b[2mLoading {s}...\x1b[0m\n", .{file_path});

    var epub = Epub.load(allocator, file_path) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        try stderr.print("\x1b[1;31mError loading EPUB: {s}\x1b[0m\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer epub.deinit();

    try stdout.print("\x1b[2mLoaded {d} chapters.\x1b[0m\n", .{epub.chapters.items.len});

    var repl = Repl.init(allocator);
    defer repl.deinit();

    const config_ptr: ?*Config = if (config_loaded) &config else null;
    try repl.run(&epub, file_path_abs, config_ptr);
}
