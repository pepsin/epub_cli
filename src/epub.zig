const std = @import("std");
const ZipReader = @import("zip.zig").ZipReader;
const SimpleXml = @import("xml.zig").SimpleXml;

pub const Chapter = struct {
    id: []const u8,
    title: []const u8,
    href: []const u8,
    content: ?[]const u8,
};

pub const Epub = struct {
    allocator: std.mem.Allocator,
    data: []u8,
    zip: ZipReader,
    opf_dir: []const u8,
    title: ?[]const u8,
    author: ?[]const u8,
    chapters: std.array_list.Managed(Chapter),
    spine: std.array_list.Managed([]const u8),

    pub fn load(allocator: std.mem.Allocator, file_path: []const u8) !Epub {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const stat = try file.stat();
        const data = try allocator.alloc(u8, @intCast(stat.size));
        errdefer allocator.free(data);
        const read_len = try file.readAll(data);
        if (read_len != data.len) return error.ReadFailed;

        var zip = try ZipReader.init(allocator, data);
        errdefer zip.deinit();



        var epub = Epub{
            .allocator = allocator,
            .data = data,
            .zip = zip,
            .opf_dir = "",
            .title = null,
            .author = null,
            .chapters = std.array_list.Managed(Chapter).init(allocator),
            .spine = std.array_list.Managed([]const u8).init(allocator),
        };

        try epub.parseContainer();
        try epub.parseOpf();
        try epub.parseNcxOrNav();

        return epub;
    }

    pub fn deinit(self: *Epub) void {
        if (self.title) |t| self.allocator.free(t);
        if (self.author) |a| self.allocator.free(a);
        for (self.chapters.items) |ch| {
            self.allocator.free(ch.id);
            self.allocator.free(ch.title);
            self.allocator.free(ch.href);
            if (ch.content) |c| self.allocator.free(c);
        }
        self.chapters.deinit();
        for (self.spine.items) |s| {
            self.allocator.free(s);
        }
        self.spine.deinit();
        self.allocator.free(self.data);
        self.allocator.free(self.opf_dir);
        self.zip.deinit();
    }

    fn parseContainer(self: *Epub) !void {
        const entry = self.zip.findEntry("META-INF/container.xml") orelse return error.NoContainer;
        const content = try self.zip.readFile(entry);
        defer self.allocator.free(content);

        var xml = SimpleXml.init(self.allocator, content);
        const rootfile_path = xml.getAttrValue("rootfile", "full-path") orelse return error.NoRootfile;
        defer self.allocator.free(rootfile_path);

        const last_slash = std.mem.lastIndexOf(u8, rootfile_path, "/");
        self.opf_dir = if (last_slash) |si|
            try self.allocator.dupe(u8, rootfile_path[0 .. si + 1])
        else
            try self.allocator.dupe(u8, "");
    }

    fn parseOpf(self: *Epub) !void {
        var opf_name_buf: [256]u8 = undefined;
        const opf_path = try std.fmt.bufPrint(&opf_name_buf, "{s}content.opf", .{self.opf_dir});

        const entry = self.zip.findEntry(opf_path) orelse blk: {
            // Try to find any .opf file
            for (self.zip.entries.items) |e| {
                if (std.mem.endsWith(u8, e.name, ".opf")) {
                    break :blk e;
                }
            }
            return error.NoOpf;
        };

        const content = try self.zip.readFile(entry);
        defer self.allocator.free(content);

        var xml = SimpleXml.init(self.allocator, content);

        // Try to get title
        if (xml.getTextUntil("dc:title")) |t| {
            self.title = t;
        }

        // Try to get author
        xml.pos = 0;
        if (xml.getTextUntil("dc:creator")) |a| {
            self.author = a;
        }

        // Parse manifest items
        var manifest_ids = std.StringHashMap([]const u8).init(self.allocator);
        defer {
            var it = manifest_ids.iterator();
            while (it.next()) |kv| {
                self.allocator.free(kv.value_ptr.*);
            }
            manifest_ids.deinit();
        }

        var search_pos: usize = 0;
        while (search_pos < content.len) {
            const tag_start = std.mem.indexOfPos(u8, content, search_pos, "<item ") orelse break;
            const tag_end = std.mem.indexOfPos(u8, content, tag_start, ">") orelse break;
            const tag = content[tag_start..tag_end];

            const id_prefix = "id=\"";
            const href_prefix = "href=\"";
            const media_prefix = "media-type=\"";

            if (std.mem.indexOf(u8, tag, id_prefix)) |id_start| {
                const id_val_start = id_start + id_prefix.len;
                const id_val_end = std.mem.indexOfPos(u8, tag, id_val_start, "\"") orelse continue;
                const id = tag[id_val_start..id_val_end];

                if (std.mem.indexOf(u8, tag, href_prefix)) |href_start| {
                    const href_val_start = href_start + href_prefix.len;
                    const href_val_end = std.mem.indexOfPos(u8, tag, href_val_start, "\"") orelse continue;
                    const href = tag[href_val_start..href_val_end];

                    if (std.mem.indexOf(u8, tag, media_prefix)) |media_start| {
                        const media_val_start = media_start + media_prefix.len;
                        const media_val_end = std.mem.indexOfPos(u8, tag, media_val_start, "\"") orelse continue;
                        const media_type = tag[media_val_start..media_val_end];

                        if (std.mem.startsWith(u8, media_type, "application/xhtml") or
                            std.mem.startsWith(u8, media_type, "text/html"))
                        {
                            const full_href = try std.mem.concat(self.allocator, u8, &.{ self.opf_dir, href });
                            try manifest_ids.put(id, full_href);
                        }
                    }
                }
            }
            search_pos = tag_end + 1;
        }

        // Parse spine
        xml.pos = 0;
        while (xml.pos < content.len) {
            const tag_start = std.mem.indexOfPos(u8, content, xml.pos, "<itemref ") orelse break;
            const tag_end = std.mem.indexOfPos(u8, content, tag_start, ">") orelse break;
            const tag = content[tag_start..tag_end];

            const idref_prefix = "idref=\"";
            if (std.mem.indexOf(u8, tag, idref_prefix)) |idref_start| {
                const idref_val_start = idref_start + idref_prefix.len;
                const idref_val_end = std.mem.indexOfPos(u8, tag, idref_val_start, "\"") orelse continue;
                const idref = tag[idref_val_start..idref_val_end];
                try self.spine.append(try self.allocator.dupe(u8, idref));
            }

            xml.pos = tag_end + 1;
        }

        // Create chapters from spine
        for (self.spine.items) |idref| {
            if (manifest_ids.get(idref)) |href| {
                const id_copy = try self.allocator.dupe(u8, idref);
                const title_copy = try self.allocator.dupe(u8, idref);
                const href_copy = try self.allocator.dupe(u8, href);
                try self.chapters.append(.{
                    .id = id_copy,
                    .title = title_copy,
                    .href = href_copy,
                    .content = null,
                });
            }
        }
    }

    fn parseNcxOrNav(self: *Epub) !void {
        // Try NCX first
        var ncx_name_buf: [256]u8 = undefined;
        const ncx_path = try std.fmt.bufPrint(&ncx_name_buf, "{s}toc.ncx", .{self.opf_dir});

        if (self.zip.findEntry(ncx_path)) |entry| {
            const content = try self.zip.readFile(entry);
            defer self.allocator.free(content);
            try self.parseNcx(content);
            return;
        }

        // Try EPUB3 nav
        for (self.zip.entries.items) |e| {
            if (std.mem.endsWith(u8, e.name, ".ncx")) {
                const content = try self.zip.readFile(e);
                defer self.allocator.free(content);
                try self.parseNcx(content);
                return;
            }
        }
    }

    fn parseNcx(self: *Epub, content: []const u8) !void {
        const NavEntry = struct {
            href: []const u8,
            title: []const u8,
        };
        var entries = std.array_list.Managed(NavEntry).init(self.allocator);
        defer {
            for (entries.items) |e| {
                self.allocator.free(e.href);
                self.allocator.free(e.title);
            }
            entries.deinit();
        }

        var search_pos: usize = 0;

        while (search_pos < content.len) {
            const navpoint_start = std.mem.indexOfPos(u8, content, search_pos, "<navPoint") orelse break;
            const navpoint_end = std.mem.indexOfPos(u8, content, navpoint_start, ">") orelse break;

            // Find the closing </navPoint>
            const navpoint_close = std.mem.indexOfPos(u8, content, navpoint_end, "</navPoint>") orelse break;
            const navpoint_content = content[navpoint_end + 1 .. navpoint_close];

            // Extract text
            const text_tag_start = std.mem.indexOf(u8, navpoint_content, "<text>") orelse {
                search_pos = navpoint_close + 1;
                continue;
            };
            const text_tag_end = std.mem.indexOf(u8, navpoint_content, "</text>") orelse {
                search_pos = navpoint_close + 1;
                continue;
            };
            const text = std.mem.trim(u8, navpoint_content[text_tag_start + 6 .. text_tag_end], " \t\r\n");

            // Extract src
            const src_prefix = "src=\"";
            if (std.mem.indexOf(u8, navpoint_content, src_prefix)) |src_start| {
                const src_val_start = src_start + src_prefix.len;
                const src_val_end = std.mem.indexOfPos(u8, navpoint_content, src_val_start, "\"") orelse {
                    search_pos = navpoint_close + 1;
                    continue;
                };
                const src = navpoint_content[src_val_start..src_val_end];

                // Strip fragment
                const src_clean = if (std.mem.indexOf(u8, src, "#")) |hash|
                    src[0..hash]
                else
                    src;

                const full_src = try std.mem.concat(self.allocator, u8, &.{ self.opf_dir, src_clean });
                const title_copy = try self.allocator.dupe(u8, text);
                try entries.append(.{ .href = full_src, .title = title_copy });
            }

            search_pos = navpoint_close + 1;
        }

        // Update chapter titles - use last matching entry
        for (self.chapters.items) |*ch| {
            var found_title: ?[]const u8 = null;
            for (entries.items) |e| {
                if (std.mem.eql(u8, e.href, ch.href)) {
                    found_title = e.title;
                }
            }
            if (found_title) |title| {
                self.allocator.free(ch.title);
                ch.title = try self.allocator.dupe(u8, title);
            }
        }
    }

    pub fn getChapterContent(self: *Epub, chapter_idx: usize) !?[]const u8 {
        if (chapter_idx >= self.chapters.items.len) return null;

        const ch = &self.chapters.items[chapter_idx];
        if (ch.content) |c| return c;

        const entry = self.zip.findEntry(ch.href) orelse return null;
        const raw_content = try self.zip.readFile(entry);

        // Strip HTML head/body tags, keep body content
        if (std.mem.indexOf(u8, raw_content, "<body")) |body_start| {
            const body_tag_end = std.mem.indexOfPos(u8, raw_content, body_start, ">") orelse 0;
            const body_close = std.mem.lastIndexOf(u8, raw_content, "</body>") orelse raw_content.len;
            const body_content = raw_content[body_tag_end + 1 .. body_close];
            ch.content = try self.allocator.dupe(u8, body_content);
            self.allocator.free(raw_content);
        } else {
            ch.content = raw_content;
        }

        return ch.content;
    }

    pub fn getChapterByHref(self: *Epub, href: []const u8) ?usize {
        for (self.chapters.items, 0..) |ch, i| {
            if (std.mem.eql(u8, ch.href, href)) return i;
        }
        return null;
    }
};
