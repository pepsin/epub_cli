const std = @import("std");
const names = @import("names.zig");

pub const BookProgress = struct {
    chapter: usize,
    last_opened: i64,
    names: bool,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    books: std.StringHashMap(BookProgress),
    detected_names: std.StringHashMap([][]const u8),

    pub fn init(allocator: std.mem.Allocator) !Config {
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
            return error.NoHomeDir;
        };
        defer allocator.free(home);

        const path = try std.fs.path.join(allocator, &.{ home, ".epub_repl.json" });
        errdefer allocator.free(path);

        var books = std.StringHashMap(BookProgress).init(allocator);
        errdefer books.deinit();

        var detected_names = std.StringHashMap([][]const u8).init(allocator);
        errdefer {
            var dn_it = detected_names.iterator();
            while (dn_it.next()) |e| {
                for (e.value_ptr.*) |n| allocator.free(n);
                allocator.free(e.value_ptr.*);
                allocator.free(e.key_ptr.*);
            }
            detected_names.deinit();
        }

        const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                return Config{
                    .allocator = allocator,
                    .path = path,
                    .books = books,
                    .detected_names = detected_names,
                };
            },
            else => |e| {
                const stderr = std.fs.File.stderr().deprecatedWriter();
                stderr.print("Warning: could not read config: {s}\n", .{@errorName(e)}) catch {};
                return Config{
                    .allocator = allocator,
                    .path = path,
                    .books = books,
                    .detected_names = detected_names,
                };
            },
        };
        defer allocator.free(content);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
            const stderr = std.fs.File.stderr().deprecatedWriter();
            stderr.print("Warning: could not parse config: {s}\n", .{@errorName(err)}) catch {};
            return Config{
                .allocator = allocator,
                .path = path,
                .books = books,
                .detected_names = detected_names,
            };
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return Config{
                .allocator = allocator,
                .path = path,
                .books = books,
                .detected_names = detected_names,
            };
        }

        var it = root.object.iterator();
        while (it.next()) |entry| {
            const book_path = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(book_path);

            const obj = entry.value_ptr.*;
            if (obj != .object) {
                allocator.free(book_path);
                continue;
            }

            const chapter_val = obj.object.get("chapter") orelse {
                allocator.free(book_path);
                continue;
            };
            const last_opened_val = obj.object.get("last_opened") orelse {
                allocator.free(book_path);
                continue;
            };

            const chapter: usize = if (chapter_val == .integer)
                @intCast(chapter_val.integer)
            else if (chapter_val == .float)
                @intFromFloat(chapter_val.float)
            else {
                allocator.free(book_path);
                continue;
            };

            const last_opened: i64 = if (last_opened_val == .integer)
                last_opened_val.integer
            else if (last_opened_val == .float)
                @intFromFloat(last_opened_val.float)
            else {
                allocator.free(book_path);
                continue;
            };

            const names_val = obj.object.get("names");
            const names_on = if (names_val) |nv| (nv == .bool and nv.bool) else false;

            try books.put(book_path, .{ .chapter = chapter, .last_opened = last_opened, .names = names_on });

            // Parse detected_names array if present
            const dn_val = obj.object.get("detected_names");
            if (dn_val) |dn| {
                if (dn == .array) {
                    const arr = dn.array;
                    if (arr.items.len > 0) {
                        const owned_names = try allocator.alloc([]const u8, arr.items.len);
                        errdefer {
                            for (owned_names) |n| allocator.free(n);
                            allocator.free(owned_names);
                        }
                        var ok = true;
                        for (arr.items, 0..) |item, idx| {
                            if (item == .string) {
                                owned_names[idx] = try allocator.dupe(u8, item.string);
                            } else {
                                ok = false;
                                for (0..idx) |j| allocator.free(owned_names[j]);
                                break;
                            }
                        }
                        if (ok) {
                            const path2 = try allocator.dupe(u8, book_path);
                            try detected_names.put(path2, owned_names);
                        } else {
                            allocator.free(owned_names);
                        }
                    }
                }
            }
        }

        return Config{
            .allocator = allocator,
            .path = path,
            .books = books,
            .detected_names = detected_names,
        };
    }

    pub fn deinit(self: *Config) void {
        var it = self.books.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.books.deinit();

        var dn_it = self.detected_names.iterator();
        while (dn_it.next()) |entry| {
            for (entry.value_ptr.*) |n| self.allocator.free(n);
            self.allocator.free(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.detected_names.deinit();

        self.allocator.free(self.path);
    }

    pub fn getProgress(self: *Config, book_path: []const u8) ?usize {
        const entry = self.books.get(book_path);
        if (entry) |e| return e.chapter;
        return null;
    }

    pub fn getNames(self: *Config, book_path: []const u8) bool {
        const entry = self.books.get(book_path);
        if (entry) |e| return e.names;
        return false;
    }

    pub fn setProgress(self: *Config, book_path: []const u8, chapter: usize, names_on: bool) !void {
        const owned_path = try self.allocator.dupe(u8, book_path);
        errdefer self.allocator.free(owned_path);

        const now = std.time.timestamp();

        const gop = try self.books.getOrPut(owned_path);
        if (gop.found_existing) {
            self.allocator.free(owned_path);
            gop.value_ptr.* = .{ .chapter = chapter, .last_opened = now, .names = names_on };
        } else {
            gop.value_ptr.* = .{ .chapter = chapter, .last_opened = now, .names = names_on };
        }

        try self.save();
    }

    pub fn setDetectedNames(self: *Config, book_path: []const u8, name_list: [][]const u8) !void {
        // Free old names if any
        if (self.detected_names.getPtr(book_path)) |old| {
            for (old.*) |name| self.allocator.free(name);
            self.allocator.free(old.*);
        }

        if (name_list.len == 0) {
            // Just remove the entry if empty
            _ = self.detected_names.remove(book_path);
            try self.save();
            return;
        }

        const owned_names = try self.allocator.alloc([]const u8, name_list.len);
        errdefer {
            for (owned_names) |n| self.allocator.free(n);
            self.allocator.free(owned_names);
        }
        for (name_list, 0..) |name, i| {
            owned_names[i] = try self.allocator.dupe(u8, name);
        }

        const owned_path = try self.allocator.dupe(u8, book_path);
        errdefer self.allocator.free(owned_path);

        const gop = try self.detected_names.getOrPut(owned_path);
        if (gop.found_existing) {
            self.allocator.free(owned_path);
            for (gop.value_ptr.*) |n| self.allocator.free(n);
            self.allocator.free(gop.value_ptr.*);
        }
        gop.value_ptr.* = owned_names;

        try self.save();
    }

    pub fn loadNameSet(self: *Config, allocator: std.mem.Allocator, book_path: []const u8) !?names.NameSet {
        const entry = self.detected_names.get(book_path);
        if (entry == null) return null;

        var set = names.NameSet.init(allocator);
        errdefer {
            var it = set.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            set.deinit();
        }

        const name_list = entry.?;
        for (name_list, 0..) |name, i| {
            const dup = try allocator.dupe(u8, name);
            try set.put(dup, i % 8);
        }

        return set;
    }

    pub fn save(self: *Config) !void {
        var buf = std.array_list.Managed(u8).init(self.allocator);
        defer buf.deinit();

        try buf.appendSlice("{\n");

        var it = self.books.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) try buf.appendSlice(",\n");
            first = false;

            try buf.appendSlice("  \"");
            try jsonEscape(entry.key_ptr.*, buf.writer());
            try buf.appendSlice("\": {\n");
            try std.fmt.format(buf.writer(), "    \"chapter\": {d},\n", .{entry.value_ptr.chapter});
            try std.fmt.format(buf.writer(), "    \"last_opened\": {d},\n", .{entry.value_ptr.last_opened});
            try std.fmt.format(buf.writer(), "    \"names\": {},\n", .{entry.value_ptr.names});

            try buf.appendSlice("    \"detected_names\": [");
            if (self.detected_names.get(entry.key_ptr.*)) |dn_list| {
                for (dn_list, 0..) |name, i| {
                    if (i > 0) try buf.appendSlice(", ");
                    try buf.appendSlice("\"");
                    try jsonEscape(name, buf.writer());
                    try buf.appendSlice("\"");
                }
            }
            try buf.appendSlice("]\n");
            try buf.appendSlice("  }");
        }

        try buf.appendSlice("\n}\n");

        const file = try std.fs.cwd().createFile(self.path, .{});
        defer file.close();

        try file.writeAll(buf.items);
    }
};

fn jsonEscape(str: []const u8, writer: anytype) !void {
    for (str) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}
