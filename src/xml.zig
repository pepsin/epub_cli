const std = @import("std");

pub const XmlToken = union(enum) {
    start_tag: struct { name: []const u8, attrs: std.StringHashMap([]const u8) },
    end_tag: []const u8,
    text: []const u8,
    eof,
};

pub const SimpleXml = struct {
    allocator: std.mem.Allocator,
    content: []const u8,
    pos: usize,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) SimpleXml {
        return .{
            .allocator = allocator,
            .content = content,
            .pos = 0,
        };
    }

    pub fn getTextUntil(self: *SimpleXml, tag_name: []const u8) ?[]const u8 {
        while (self.pos < self.content.len) {
            const tag_start = std.mem.indexOfPos(u8, self.content, self.pos, "<") orelse return null;
            const tag_end = std.mem.indexOfPos(u8, self.content, tag_start, ">") orelse return null;
            const tag_content = std.mem.trim(u8, self.content[tag_start + 1 .. tag_end], " \t\r\n");

            if (std.mem.startsWith(u8, tag_content, "/") and std.mem.eql(u8, tag_content[1..], tag_name)) {
                const text = self.content[self.pos..tag_start];
                self.pos = tag_end + 1;
                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                return self.allocator.dupe(u8, trimmed) catch null;
            }

            self.pos = tag_end + 1;
        }
        return null;
    }

    pub fn getAttrValue(self: *SimpleXml, tag_name: []const u8, attr_name: []const u8) ?[]const u8 {
        while (self.pos < self.content.len) {
            const tag_start = std.mem.indexOfPos(u8, self.content, self.pos, "<") orelse return null;
            const tag_end = std.mem.indexOfPos(u8, self.content, tag_start, ">") orelse return null;

            if (tag_end == tag_start + 1) {
                self.pos = tag_end + 1;
                continue;
            }

            const tag_content = self.content[tag_start + 1 .. tag_end];
            const space_idx = std.mem.indexOfAny(u8, tag_content, " \t\r\n");
            const current_tag = if (space_idx) |si| tag_content[0..si] else tag_content;

            if (std.mem.eql(u8, current_tag, tag_name)) {
                const attr_search = std.mem.concat(self.allocator, u8, &.{ attr_name, "=\"" }) catch return null;
                defer self.allocator.free(attr_search);

                if (std.mem.indexOf(u8, tag_content, attr_search)) |attr_start| {
                    const val_start = attr_start + attr_search.len;
                    const val_end = std.mem.indexOfPos(u8, tag_content, val_start, "\"") orelse tag_content.len;
                    self.pos = tag_end + 1;
                    return self.allocator.dupe(u8, tag_content[val_start..val_end]) catch null;
                }
            }

            self.pos = tag_end + 1;
        }
        return null;
    }

    pub fn findAllTagAttrs(self: *SimpleXml, tag_name: []const u8, attr_name: []const u8, results: *std.array_list.Managed([]const u8)) !void {
        var search_pos: usize = 0;
        while (search_pos < self.content.len) {
            const tag_start = std.mem.indexOfPos(u8, self.content, search_pos, "<") orelse break;
            const tag_end = std.mem.indexOfPos(u8, self.content, tag_start, ">") orelse break;

            if (tag_end == tag_start + 1) {
                search_pos = tag_end + 1;
                continue;
            }

            const tag_content = self.content[tag_start + 1 .. tag_end];
            const space_idx = std.mem.indexOfAny(u8, tag_content, " \t\r\n");
            const current_tag = if (space_idx) |si| tag_content[0..si] else tag_content;

            if (std.mem.eql(u8, current_tag, tag_name)) {
                const attr_prefix = try std.mem.concat(self.allocator, u8, &.{ attr_name, "=\"" });
                defer self.allocator.free(attr_prefix);

                if (std.mem.indexOf(u8, tag_content, attr_prefix)) |attr_start| {
                    const val_start = attr_start + attr_prefix.len;
                    const val_end = std.mem.indexOfPos(u8, tag_content, val_start, "\"") orelse tag_content.len;
                    const val = try self.allocator.dupe(u8, tag_content[val_start..val_end]);
                    try results.append(val);
                }
            }

            search_pos = tag_end + 1;
        }
    }
};
