const std = @import("std");
const Epub = @import("epub.zig").Epub;
const html = @import("html.zig");
const names = @import("names.zig");
const term = @import("term.zig");
const Config = @import("config.zig").Config;

const NameParserCtx = struct {
    allocator: std.mem.Allocator,
    contents: []const []const u8,
    mutex: std.Thread.Mutex,
    done: bool,
    name_set: ?names.NameSet,
    err: ?anyerror,
};

fn nameParserThreadFn(ctx: *NameParserCtx) void {
    const set = names.buildNameSetFromContents(ctx.allocator, ctx.contents) catch |err| {
        ctx.mutex.lock();
        ctx.err = err;
        ctx.done = true;
        ctx.mutex.unlock();
        ctx.allocator.free(ctx.contents);
        return;
    };
    ctx.mutex.lock();
    ctx.name_set = set;
    ctx.done = true;
    ctx.mutex.unlock();
    ctx.allocator.free(ctx.contents);
}

pub const Repl = struct {
    allocator: std.mem.Allocator,
    epub: ?*Epub,
    current_chapter: usize,
    running: bool,
    last_search: ?[]const u8,
    search_mode: SearchMode,
    name_highlight: bool,
    name_set: ?names.NameSet,
    book_path: []const u8,
    config: ?*Config,
    name_parser_thread: ?std.Thread,
    name_parser_ctx: ?*NameParserCtx,

    const SearchMode = enum {
        current_chapter,
        all_chapters,
    };

    const PagerAction = enum {
        quit,
        next_chapter,
        prev_chapter,
    };

    pub fn init(allocator: std.mem.Allocator) Repl {
        return .{
            .allocator = allocator,
            .epub = null,
            .current_chapter = 0,
            .running = true,
            .last_search = null,
            .search_mode = .current_chapter,
            .name_highlight = false,
            .name_set = null,
            .book_path = "",
            .config = null,
            .name_parser_thread = null,
            .name_parser_ctx = null,
        };
    }

    pub fn deinit(self: *Repl) void {
        if (self.last_search) |s| self.allocator.free(s);
        if (self.name_set) |*set| {
            names.deinitNameSet(set, self.allocator);
        }
        if (self.name_parser_thread) |thread| {
            thread.join();
            self.name_parser_thread = null;
        }
        if (self.name_parser_ctx) |ctx| {
            if (ctx.name_set) |*set| names.deinitNameSet(set, self.allocator);
            self.allocator.destroy(ctx);
            self.name_parser_ctx = null;
        }
    }

    fn stdout() std.fs.File.DeprecatedWriter {
        return std.fs.File.stdout().deprecatedWriter();
    }

    fn checkNameParserResult(self: *Repl) !void {
        const ctx = self.name_parser_ctx orelse return;

        ctx.mutex.lock();
        const done = ctx.done;
        const name_set = ctx.name_set;
        const err = ctx.err;
        ctx.name_set = null;
        ctx.mutex.unlock();

        if (!done) return;

        if (self.name_parser_thread) |thread| {
            thread.join();
            self.name_parser_thread = null;
        }

        if (err) |e| {
            try stdout().print("\x1b[1;33mName parsing failed: {s}\x1b[0m\n", .{@errorName(e)});
        } else if (name_set) |set| {
            self.name_set = set;
            self.name_highlight = true;
            self.saveProgress();

            if (self.config) |cfg| {
                var name_list = std.array_list.Managed([]const u8).init(self.allocator);
                defer name_list.deinit();
                var it = set.iterator();
                while (it.next()) |entry| {
                    try name_list.append(entry.key_ptr.*);
                }
                cfg.setDetectedNames(self.book_path, name_list.items) catch {};
            }

            var count: usize = 0;
            var it = set.iterator();
            while (it.next()) |_| count += 1;
            try stdout().print("\x1b[1;32m✓ Name highlighting auto-enabled ({d} names detected)\x1b[0m\n", .{count});
        }

        self.allocator.destroy(ctx);
        self.name_parser_ctx = null;
    }

    pub fn run(self: *Repl, epub: *Epub, book_path: []const u8, config: ?*Config) !void {
        self.epub = epub;
        self.book_path = book_path;
        self.config = config;

        // Restore saved progress
        if (config) |cfg| {
            if (cfg.getProgress(book_path)) |saved_chapter| {
                if (saved_chapter < epub.chapters.items.len) {
                    self.current_chapter = saved_chapter;
                    try stdout().print("\x1b[1;33mResumed from chapter {d}\x1b[0m\n", .{saved_chapter + 1});
                }
            }
            self.name_highlight = cfg.getNames(book_path);

            // Restore detected names if available
            if (self.name_highlight) {
                if (cfg.loadNameSet(self.allocator, book_path)) |maybe_set| {
                    if (maybe_set) |set| {
                        self.name_set = set;
                    }
                } else |err| {
                    try stdout().print("\x1b[1;33mNote: could not restore name set ({s}), will rebuild on demand.\x1b[0m\n", .{@errorName(err)});
                }
            }
        }

        // Start background name parser if no saved names
        if (self.name_set == null and self.epub != null) {
            const e = self.epub.?;
            var contents = std.array_list.Managed([]const u8).init(self.allocator);
            defer contents.deinit();
            for (0..e.chapters.items.len) |i| {
                const content = try e.getChapterContent(i);
                try contents.append(content orelse "");
            }
            const contents_slice = try self.allocator.dupe([]const u8, contents.items);
            const ctx = try self.allocator.create(NameParserCtx);
            ctx.* = .{
                .allocator = self.allocator,
                .contents = contents_slice,
                .mutex = .{},
                .done = false,
                .name_set = null,
                .err = null,
            };
            self.name_parser_thread = std.Thread.spawn(.{}, nameParserThreadFn, .{ctx}) catch |err| blk: {
                self.allocator.free(contents_slice);
                self.allocator.destroy(ctx);
                try stdout().print("\x1b[1;33mWarning: could not start name parser thread ({s})\x1b[0m\n", .{@errorName(err)});
                break :blk null;
            };
            if (self.name_parser_thread != null) {
                self.name_parser_ctx = ctx;
            }
        }

        try self.printWelcome();
        if (try self.runTocSelector()) |idx| {
            self.current_chapter = idx;
            self.saveProgress();
            try self.showCurrentChapter();
        }

        try self.checkNameParserResult();

        var buf: [1024]u8 = undefined;
        while (self.running) {
            try self.checkNameParserResult();
            try self.printPrompt();
            const line = try std.fs.File.stdin().deprecatedReader().readUntilDelimiterOrEof(&buf, '\n');
            if (line == null) break;

            const trimmed = std.mem.trim(u8, line.?, " \t\r\n");
            if (trimmed.len == 0) continue;

            try self.handleCommand(trimmed);
        }
    }

    fn printPrompt(self: *Repl) !void {
        const ch = if (self.epub) |e| e.chapters.items[self.current_chapter] else null;
        if (ch) |chapter| {
            try stdout().print("\x1b[1;36m[{d}/{d}] {s}\x1b[0m > ", .{
                self.current_chapter + 1,
                self.epub.?.chapters.items.len,
                chapter.title,
            });
        } else {
            try stdout().print("\x1b[1;36mepub>\x1b[0m ", .{});
        }
    }

    fn printWelcome(self: *Repl) !void {
        try stdout().print("\n", .{});
        try stdout().print("\x1b[1;35m╔══════════════════════════════════════╗\x1b[0m\n", .{});
        try stdout().print("\x1b[1;35m║      📚 EPUB Interactive Reader      ║\x1b[0m\n", .{});
        try stdout().print("\x1b[1;35m╚══════════════════════════════════════╝\x1b[0m\n", .{});
        try stdout().print("\n", .{});

        if (self.epub) |e| {
            if (e.title) |t| {
                try stdout().print("\x1b[1;33mTitle:\x1b[0m  {s}\n", .{t});
            }
            if (e.author) |a| {
                try stdout().print("\x1b[1;33mAuthor:\x1b[0m {s}\n", .{a});
            }
            try stdout().print("\x1b[1;33mChapters:\x1b[0m {d}\n", .{e.chapters.items.len});
        }
        try stdout().print("\n", .{});
    }

    fn showToc(self: *Repl) !void {
        if (self.epub == null) return;
        const e = self.epub.?;

        try stdout().print("\x1b[1;32m┌────────── Table of Contents ──────────┐\x1b[0m\n", .{});
        for (e.chapters.items, 0..) |ch, i| {
            const marker = if (i == self.current_chapter) "\x1b[1;36m▶\x1b[0m" else " ";
            try stdout().print("{s} \x1b[1m{d:3}\x1b[0m. {s}\n", .{ marker, i + 1, ch.title });
        }
        try stdout().print("\x1b[1;32m└───────────────────────────────────────┘\x1b[0m\n", .{});
        try stdout().print("\n", .{});
    }

    fn runTocSelector(self: *Repl) !?usize {
        if (self.epub == null) return null;

        const size = term.getTerminalSize() catch {
            try self.showToc();
            return null;
        };

        term.enableRawMode() catch {
            try self.showToc();
            return null;
        };
        defer term.disableRawMode();

        const total = self.epub.?.chapters.items.len;
        var selected: usize = self.current_chapter;
        var top: usize = 0;

        while (true) {
            const header_rows: u16 = 1;
            const footer_rows: u16 = 1;
            const visible = if (size.rows > header_rows + footer_rows) size.rows - header_rows - footer_rows else 1;

            // Keep selected item in view
            if (selected < top) top = selected;
            if (selected >= top + visible) top = selected - visible + 1;
            if (top + visible > total) top = if (total > visible) total - visible else 0;

            try stdout().writeAll("\x1b[2J\x1b[H");
            try stdout().print("\x1b[1;32m┌────────── Table of Contents ({d}/{d}) ──────────┐\x1b[0m\n", .{ selected + 1, total });

            const end = @min(top + visible, total);
            for (self.epub.?.chapters.items[top..end], top..) |ch, i| {
                const marker = if (i == selected) "\x1b[1;36m▶\x1b[0m" else " ";
                const here = if (i == self.current_chapter) " \x1b[2m[here]\x1b[0m" else "";
                try stdout().print("{s} \x1b[1m{d:3}\x1b[0m. {s}{s}\n", .{ marker, i + 1, ch.title, here });
            }

            try stdout().print("\x1b[7m[↑/↓/j/k] move  [Enter] select  [q] cancel\x1b[0m", .{});

            const key = term.readKey() catch break;
            switch (key) {
                .char => |c| switch (c) {
                    'q', 'Q' => {
                        try stdout().writeAll("\n");
                        return null;
                    },
                    'j', 'J' => {
                        if (selected + 1 < total) selected += 1;
                    },
                    'k', 'K' => {
                        if (selected > 0) selected -= 1;
                    },
                    'g' => selected = 0,
                    'G' => {
                        if (total > 0) selected = total - 1;
                    },
                    '\r', '\n' => {
                        try stdout().writeAll("\n");
                        return selected;
                    },
                    else => {},
                },
                .up => {
                    if (selected > 0) selected -= 1;
                },
                .down => {
                    if (selected + 1 < total) selected += 1;
                },
                .home => selected = 0,
                .end => selected = total - 1,
                .escape => {
                    try stdout().writeAll("\n");
                    return null;
                },
                else => {},
            }
        }

        try stdout().writeAll("\n");
        return null;
    }

    fn lineDisplayWidth(line: []const u8) usize {
        var width: usize = 0;
        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == '\x1b' and i + 1 < line.len and line[i + 1] == '[') {
                i += 2;
                while (i < line.len and ((line[i] >= '0' and line[i] <= '9') or line[i] == ';' or line[i] == '?')) {
                    i += 1;
                }
                if (i < line.len) i += 1; // skip command char
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(line[i]) catch {
                i += 1;
                width += 1;
                continue;
            };
            if (i + len > line.len) {
                i += 1;
                width += 1;
                continue;
            }
            const cp = std.unicode.utf8Decode(line[i..][0..len]) catch {
                i += 1;
                width += 1;
                continue;
            };
            const is_wide = (cp >= 0x4E00 and cp <= 0x9FFF) or
                            (cp >= 0x3400 and cp <= 0x4DBF) or
                            (cp >= 0x3000 and cp <= 0x303F) or
                            (cp >= 0xFF01 and cp <= 0xFF60) or
                            (cp >= 0xFFE0 and cp <= 0xFFE6);
            width += if (is_wide) 2 else 1;
            i += len;
        }
        return width;
    }

    fn linePhysicalRows(line: []const u8, cols: usize) usize {
        const w = lineDisplayWidth(line);
        return if (w == 0) 1 else (w + cols - 1) / cols;
    }

    fn printLineFromRow(writer: anytype, line: []const u8, start_row: usize, cols: usize) !void {
        if (start_row == 0) {
            try writer.print("{s}\n", .{line});
            return;
        }

        const skip_width = start_row * cols;
        var width: usize = 0;
        var i: usize = 0;

        while (i < line.len and width < skip_width) {
            if (line[i] == '\x1b' and i + 1 < line.len and line[i + 1] == '[') {
                try writer.writeAll("\x1b[");
                i += 2;
                while (i < line.len and ((line[i] >= '0' and line[i] <= '9') or line[i] == ';' or line[i] == '?')) {
                    try writer.writeByte(line[i]);
                    i += 1;
                }
                if (i < line.len) {
                    try writer.writeByte(line[i]);
                    i += 1;
                }
                continue;
            }

            const len = std.unicode.utf8ByteSequenceLength(line[i]) catch {
                width += 1;
                i += 1;
                continue;
            };
            if (i + len > line.len) {
                width += 1;
                i += 1;
                continue;
            }
            const cp = std.unicode.utf8Decode(line[i..][0..len]) catch {
                width += 1;
                i += 1;
                continue;
            };
            const is_wide = (cp >= 0x4E00 and cp <= 0x9FFF) or
                            (cp >= 0x3400 and cp <= 0x4DBF) or
                            (cp >= 0x3000 and cp <= 0x303F) or
                            (cp >= 0xFF01 and cp <= 0xFF60) or
                            (cp >= 0xFFE0 and cp <= 0xFFE6);
            const char_width: usize = if (is_wide) 2 else 1;

            if (width + char_width > skip_width) {
                try writer.writeAll(line[i..][0..len]);
                width += char_width;
                i += len;
                break;
            }

            width += char_width;
            i += len;
        }

        try writer.writeAll(line[i..]);
        try writer.writeByte('\n');
    }

    fn runPager(self: *Repl, text: []const u8) !PagerAction {
        const size = term.getTerminalSize() catch {
            try stdout().print("{s}\n", .{text});
            return .quit;
        };

        var lines = std.array_list.Managed([]const u8).init(self.allocator);
        defer lines.deinit();

        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            try lines.append(line);
        }
        if (lines.items.len == 0) return .quit;

        term.enableRawMode() catch {
            try stdout().print("{s}\n", .{text});
            return .quit;
        };
        defer term.disableRawMode();

        var top_line: usize = 0;
        var top_row: usize = 0;

        while (true) {
            const current_size = term.getTerminalSize() catch size;
            const visible_lines = if (current_size.rows > 1) current_size.rows - 1 else current_size.rows;
            const cols = if (current_size.cols > 0) current_size.cols else 80;

            try stdout().writeAll("\x1b[2J\x1b[H");

            var phys_rows: usize = 0;
            var i: usize = top_line;
            while (i < lines.items.len) : (i += 1) {
                const line = lines.items[i];
                const line_rows = linePhysicalRows(line, cols);
                const start_row = if (i == top_line) top_row else 0;
                const visible_rows = if (line_rows > start_row) line_rows - start_row else 0;
                if (phys_rows + visible_rows > visible_lines) break;
                if (visible_rows > 0) {
                    if (start_row == 0) {
                        try stdout().print("{s}\n", .{line});
                    } else {
                        try printLineFromRow(stdout(), line, start_row, cols);
                    }
                }
                phys_rows += visible_rows;
            }

            const status_row = visible_lines + 1;
            try stdout().print("\x1b[{d};1H\x1b[7m-- {d}/{d} -- [j/k/↵/n/p/u/d/g/G/q] --\x1b[0m", .{
                status_row,
                top_line + 1,
                lines.items.len,
            });

            const key = term.readKey() catch break;
            switch (key) {
                .char => |c| switch (c) {
                    'q', 'Q' => return .quit,
                    'n', 'N' => return .next_chapter,
                    'p', 'P' => return .prev_chapter,
                    '\r', '\n' => return .next_chapter,
                    'j', 'J', ' ' => {
                        const line_rows = linePhysicalRows(lines.items[top_line], cols);
                        if (top_row + 1 < line_rows) {
                            top_row += 1;
                        } else if (top_line + 1 < lines.items.len) {
                            top_line += 1;
                            top_row = 0;
                        }
                    },
                    'k', 'K' => {
                        if (top_row > 0) {
                            top_row -= 1;
                        } else if (top_line > 0) {
                            top_line -= 1;
                            top_row = linePhysicalRows(lines.items[top_line], cols);
                            if (top_row > 0) top_row -= 1;
                        }
                    },
                    'd', 'D' => {
                        var remaining: usize = visible_lines / 2;
                        if (remaining == 0) remaining = 1;
                        while (remaining > 0) {
                            const line_rows = linePhysicalRows(lines.items[top_line], cols);
                            const avail = line_rows - top_row;
                            if (remaining < avail) {
                                top_row += remaining;
                                break;
                            }
                            remaining -= avail;
                            top_line += 1;
                            top_row = 0;
                            if (top_line >= lines.items.len) {
                                top_line = lines.items.len - 1;
                                top_row = 0;
                                break;
                            }
                        }
                    },
                    'u', 'U' => {
                        var remaining: usize = visible_lines / 2;
                        if (remaining == 0) remaining = 1;
                        while (remaining > 0) {
                            if (top_row > 0) {
                                const back = @min(top_row, remaining);
                                top_row -= back;
                                remaining -= back;
                                if (remaining == 0) break;
                            }
                            if (top_line == 0) break;
                            top_line -= 1;
                            top_row = linePhysicalRows(lines.items[top_line], cols);
                        }
                    },
                    'g' => {
                        top_line = 0;
                        top_row = 0;
                    },
                    'G' => {
                        var rows: usize = 0;
                        top_line = lines.items.len;
                        top_row = 0;
                        while (top_line > 0) {
                            const prev_rows = linePhysicalRows(lines.items[top_line - 1], cols);
                            if (rows + prev_rows > visible_lines) {
                                top_row = prev_rows - (visible_lines - rows);
                                break;
                            }
                            rows += prev_rows;
                            top_line -= 1;
                        }
                        if (top_line == 0) top_row = 0;
                    },
                    else => {},
                },
                .up => {
                    if (top_row > 0) {
                        top_row -= 1;
                    } else if (top_line > 0) {
                        top_line -= 1;
                        top_row = linePhysicalRows(lines.items[top_line], cols);
                        if (top_row > 0) top_row -= 1;
                    }
                },
                .down => {
                    const line_rows = linePhysicalRows(lines.items[top_line], cols);
                    if (top_row + 1 < line_rows) {
                        top_row += 1;
                    } else if (top_line + 1 < lines.items.len) {
                        top_line += 1;
                        top_row = 0;
                    }
                },
                .page_up => {
                    var remaining: usize = visible_lines / 2;
                    if (remaining == 0) remaining = 1;
                    while (remaining > 0) {
                        if (top_row > 0) {
                            const back = @min(top_row, remaining);
                            top_row -= back;
                            remaining -= back;
                            if (remaining == 0) break;
                        }
                        if (top_line == 0) break;
                        top_line -= 1;
                        top_row = linePhysicalRows(lines.items[top_line], cols);
                    }
                },
                .page_down => {
                    var remaining: usize = visible_lines / 2;
                    if (remaining == 0) remaining = 1;
                    while (remaining > 0) {
                        const line_rows = linePhysicalRows(lines.items[top_line], cols);
                        const avail = line_rows - top_row;
                        if (remaining < avail) {
                            top_row += remaining;
                            break;
                        }
                        remaining -= avail;
                        top_line += 1;
                        top_row = 0;
                        if (top_line >= lines.items.len) {
                            top_line = lines.items.len - 1;
                            top_row = 0;
                            break;
                        }
                    }
                },
                .home => {
                    top_line = 0;
                    top_row = 0;
                },
                .end => {
                    var rows: usize = 0;
                    top_line = lines.items.len;
                    top_row = 0;
                    while (top_line > 0) {
                        const prev_rows = linePhysicalRows(lines.items[top_line - 1], cols);
                        if (rows + prev_rows > visible_lines) {
                            top_row = prev_rows - (visible_lines - rows);
                            break;
                        }
                        rows += prev_rows;
                        top_line -= 1;
                    }
                    if (top_line == 0) top_row = 0;
                },
                .escape => return .quit,
                else => {},
            }
        }

        try stdout().writeAll("\n");
        return .quit;
    }

    fn showCurrentChapter(self: *Repl) !void {
        while (true) {
            try self.checkNameParserResult();
            if (self.epub == null) return;
            const e = self.epub.?;

            if (self.current_chapter >= e.chapters.items.len) {
                try stdout().print("\x1b[1;31mNo more chapters.\x1b[0m\n", .{});
                return;
            }

            const ch = e.chapters.items[self.current_chapter];
            const raw_content = try e.getChapterContent(self.current_chapter);

            if (raw_content == null) {
                try stdout().print("\x1b[1;31mFailed to load chapter content.\x1b[0m\n", .{});
                return;
            }

            const processed = if (self.name_highlight)
                try html.injectNameTags(self.allocator, raw_content.?, self.name_set)
            else
                raw_content.?;
            defer if (self.name_highlight) self.allocator.free(processed);

            const rendered = if (self.last_search) |search_term|
                try html.renderWithSearchHighlight(self.allocator, processed, search_term)
            else
                try html.renderToTerminal(self.allocator, processed);
            defer self.allocator.free(rendered);

            const header = try std.fmt.allocPrint(self.allocator,
                "\n\x1b[1;35m╔══════════════════════════════════════════════════════════════╗\x1b[0m\n" ++
                "\x1b[1;35m║  Chapter {d}/{d}: {s}\x1b[0m\n" ++
                "\x1b[1;35m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n\n", .{
                self.current_chapter + 1,
                e.chapters.items.len,
                ch.title,
            });
            defer self.allocator.free(header);

            const footer = try std.fmt.allocPrint(self.allocator,
                "\n\x1b[2m── End of Chapter {d}/{d} ──\x1b[0m\n\n", .{
                self.current_chapter + 1,
                e.chapters.items.len,
                });
            defer self.allocator.free(footer);

            const full_text = try std.mem.concat(self.allocator, u8, &.{ header, rendered, footer });
            defer self.allocator.free(full_text);

            const action = try self.runPager(full_text);
            switch (action) {
                .quit => break,
                .next_chapter => {
                    if (self.current_chapter + 1 >= e.chapters.items.len) {
                        try stdout().print("\x1b[1;33mAlready at the last chapter.\x1b[0m\n", .{});
                        break;
                    }
                    self.current_chapter += 1;
                    self.saveProgress();
                },
                .prev_chapter => {
                    if (self.current_chapter == 0) {
                        try stdout().print("\x1b[1;33mAlready at the first chapter.\x1b[0m\n", .{});
                        break;
                    }
                    self.current_chapter -= 1;
                    self.saveProgress();
                },
            }
        }
    }

    fn saveProgress(self: *Repl) void {
        if (self.config) |cfg| {
            cfg.setProgress(self.book_path, self.current_chapter, self.name_highlight) catch {};
        }
    }

    fn goToChapter(self: *Repl, num_str: []const u8) !void {
        const num = std.fmt.parseInt(usize, num_str, 10) catch {
            try stdout().print("\x1b[1;31mInvalid chapter number: {s}\x1b[0m\n", .{num_str});
            return;
        };

        if (self.epub == null) return;
        const e = self.epub.?;

        if (num < 1 or num > e.chapters.items.len) {
            try stdout().print("\x1b[1;31mChapter {d} does not exist. Range: 1-{d}\x1b[0m\n", .{ num, e.chapters.items.len });
            return;
        }

        self.current_chapter = num - 1;
        self.saveProgress();
        try self.showCurrentChapter();
    }

    fn nextChapter(self: *Repl) !void {
        if (self.epub == null) return;
        if (self.current_chapter + 1 >= self.epub.?.chapters.items.len) {
            try stdout().print("\x1b[1;33mAlready at the last chapter.\x1b[0m\n", .{});
            return;
        }
        self.current_chapter += 1;
        self.saveProgress();
        try self.showCurrentChapter();
    }

    fn prevChapter(self: *Repl) !void {
        if (self.current_chapter == 0) {
            try stdout().print("\x1b[1;33mAlready at the first chapter.\x1b[0m\n", .{});
            return;
        }
        self.current_chapter -= 1;
        self.saveProgress();
        try self.showCurrentChapter();
    }

    fn doSearch(self: *Repl, query: []const u8) !void {
        if (self.epub == null) return;
        const e = self.epub.?;

        if (query.len == 0) {
            try stdout().print("\x1b[1;31mPlease provide a search query.\x1b[0m\n", .{});
            return;
        }

        // Save search term
        if (self.last_search) |s| self.allocator.free(s);
        self.last_search = try self.allocator.dupe(u8, query);

        const lower_query = try std.ascii.allocLowerString(self.allocator, query);
        defer self.allocator.free(lower_query);

        try stdout().print("\x1b[1;36mSearching for \"{s}\"...\x1b[0m\n", .{query});
        try stdout().print("\n", .{});

        var found_count: usize = 0;

        if (self.search_mode == .current_chapter) {
            const raw_content = try e.getChapterContent(self.current_chapter);
            if (raw_content) |content| {
                const lower_content = try std.ascii.allocLowerString(self.allocator, content);
                defer self.allocator.free(lower_content);

                if (std.mem.indexOf(u8, lower_content, lower_query)) |_| {
                    found_count += 1;
                    try stdout().print("\x1b[1;32mFound in current chapter:\x1b[0m\n", .{});
                    try self.showCurrentChapter();
                } else {
                    try stdout().print("\x1b[1;33mNot found in current chapter.\x1b[0m\n", .{});
                }
            }
        } else {
            for (e.chapters.items, 0..) |ch, i| {
                const raw_content = try e.getChapterContent(i);
                if (raw_content == null) continue;

                const lower_content = try std.ascii.allocLowerString(self.allocator, raw_content.?);
                defer self.allocator.free(lower_content);

                if (std.mem.indexOf(u8, lower_content, lower_query)) |_| {
                    found_count += 1;
                    try stdout().print("\x1b[1;32m[{d}] {s}\x1b[0m\n", .{ i + 1, ch.title });
                }
            }

            if (found_count > 0) {
                try stdout().print("\n\x1b[1;32mFound in {d} chapter(s).\x1b[0m\n", .{found_count});
                try stdout().print("Use \x1b[1m/go <number>\x1b[0m to navigate to a chapter.\n", .{});
            } else {
                try stdout().print("\x1b[1;33mNo matches found.\x1b[0m\n", .{});
            }
        }
        try stdout().print("\n", .{});
    }

    fn showHelp(_: *Repl) !void {
        try stdout().print("\n", .{});
        try stdout().print("\x1b[1;33m┌────────── Commands ──────────┐\x1b[0m\n", .{});
        try stdout().print("\x1b[1m  /toc, /ls       \x1b[0m Show table of contents\n", .{});
        try stdout().print("\x1b[1m  /go <n>         \x1b[0m Go to chapter n\n", .{});
        try stdout().print("\x1b[1m  /next, /n       \x1b[0m Next chapter\n", .{});
        try stdout().print("\x1b[1m  /prev, /p       \x1b[0m Previous chapter\n", .{});
        try stdout().print("\x1b[1m  /show, /cat     \x1b[0m Show current chapter\n", .{});
        try stdout().print("\x1b[1m  // <query>      \x1b[0m Search current chapter\n", .{});
        try stdout().print("\x1b[1m  /? <query>      \x1b[0m Search all chapters\n", .{});
        try stdout().print("\x1b[1m  /names          \x1b[0m Toggle name highlighting\n", .{});
        try stdout().print("\x1b[1m  /clear, /cls    \x1b[0m Clear screen\n", .{});
        try stdout().print("\x1b[1m  /info           \x1b[0m Show book info\n", .{});
        try stdout().print("\x1b[1m  /help, /h, /?   \x1b[0m Show this help\n", .{});
        try stdout().print("\x1b[1m  /quit, /q       \x1b[0m Exit reader\n", .{});
        try stdout().print("\x1b[1;33m└──────────────────────────────┘\x1b[0m\n", .{});
        try stdout().print("\x1b[2mIn chapter view: [j/k/↑/↓] scroll, [u/d] half-page, [g/G] top/bottom, [q] quit\x1b[0m\n", .{});
        try stdout().print("\n", .{});
    }

    fn handleCommand(self: *Repl, cmd_line: []const u8) !void {
        if (!std.mem.startsWith(u8, cmd_line, "/")) {
            try stdout().print("\x1b[1;33mCommands start with '/'. Type '/help' for available commands.\x1b[0m\n", .{});
            return;
        }

        const body = std.mem.trim(u8, cmd_line[1..], " \t\r\n");
        if (body.len == 0) {
            try stdout().print("\x1b[1;33mType '/help' for available commands.\x1b[0m\n", .{});
            return;
        }

        // Handle "//query" and "/?query" shortcuts
        if (std.mem.startsWith(u8, body, "/")) {
            const query = std.mem.trim(u8, body[1..], " \t\r\n");
            self.search_mode = .current_chapter;
            try self.doSearch(query);
            return;
        }
        if (std.mem.startsWith(u8, body, "?")) {
            const query = std.mem.trim(u8, body[1..], " \t\r\n");
            self.search_mode = .all_chapters;
            try self.doSearch(query);
            return;
        }

        var parts = std.mem.splitScalar(u8, body, ' ');
        const cmd = parts.next().?;
        const rest = std.mem.trim(u8, body[cmd.len..], " \t\r\n");

        if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "exit")) {
            self.saveProgress();
            self.running = false;
            try stdout().print("\x1b[1;33mGoodbye! 👋\x1b[0m\n", .{});
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "?")) {
            try self.showHelp();
        } else if (std.mem.eql(u8, cmd, "toc") or std.mem.eql(u8, cmd, "ls")) {
            if (try self.runTocSelector()) |idx| {
                self.current_chapter = idx;
                self.saveProgress();
                try self.showCurrentChapter();
            }
        } else if (std.mem.eql(u8, cmd, "go") or std.mem.eql(u8, cmd, "cd") or std.mem.eql(u8, cmd, "goto")) {
            if (rest.len == 0) {
                try stdout().print("\x1b[1;31mUsage: /go <chapter-number>\x1b[0m\n", .{});
                return;
            }
            try self.goToChapter(rest);
        } else if (std.mem.eql(u8, cmd, "next") or std.mem.eql(u8, cmd, "n")) {
            try self.nextChapter();
        } else if (std.mem.eql(u8, cmd, "prev") or std.mem.eql(u8, cmd, "p")) {
            try self.prevChapter();
        } else if (std.mem.eql(u8, cmd, "show") or std.mem.eql(u8, cmd, "cat") or std.mem.eql(u8, cmd, "read")) {
            try self.showCurrentChapter();
        } else if (std.mem.eql(u8, cmd, "search") or std.mem.eql(u8, cmd, "find")) {
            self.search_mode = .current_chapter;
            try self.doSearch(rest);
        } else if (std.mem.eql(u8, cmd, "search-all") or std.mem.eql(u8, cmd, "find-all")) {
            self.search_mode = .all_chapters;
            try self.doSearch(rest);
        } else if (std.mem.eql(u8, cmd, "clear") or std.mem.eql(u8, cmd, "cls")) {
            try stdout().writeAll("\x1b[2J\x1b[H");
        } else if (std.mem.eql(u8, cmd, "names")) {
            if (self.name_highlight) {
                // Turning OFF is always allowed
                self.name_highlight = false;
                self.saveProgress();
                try stdout().print("Name highlighting: \x1b[1;31moff\x1b[0m\n", .{});
            } else {
                // Trying to turn ON
                if (self.name_set == null and self.epub != null) {
                    if (self.name_parser_ctx != null) {
                        try stdout().print("\x1b[1;33mName detection still in progress, please wait...\x1b[0m\n", .{});
                    } else {
                        try stdout().print("\x1b[2mScanning book for recurring names...\x1b[0m\n", .{});
                        self.name_set = try names.buildNameSet(self.allocator, self.epub.?);
                        try stdout().print("\x1b[2mDone.\x1b[0m\n", .{});

                        if (self.config) |cfg| {
                            var name_list = std.array_list.Managed([]const u8).init(self.allocator);
                            defer name_list.deinit();
                            var it = self.name_set.?.iterator();
                            while (it.next()) |entry| {
                                try name_list.append(entry.key_ptr.*);
                            }
                            cfg.setDetectedNames(self.book_path, name_list.items) catch {};
                        }
                    }
                }
                if (self.name_set != null) {
                    self.name_highlight = true;
                    self.saveProgress();
                    try stdout().print("Name highlighting: \x1b[1;32mon\x1b[0m\n", .{});
                    try self.showCurrentChapter();
                }
            }
        } else if (std.mem.eql(u8, cmd, "info")) {
            try self.printWelcome();
        } else if (std.mem.eql(u8, cmd, "chapter") or std.mem.eql(u8, cmd, "ch")) {
            try stdout().print("\x1b[1;36mCurrent chapter: {d}/{d}\x1b[0m\n", .{
                self.current_chapter + 1,
                self.epub.?.chapters.items.len,
            });
        } else {
            if (std.fmt.parseInt(usize, cmd, 10)) |_| {
                try self.goToChapter(cmd);
            } else |_| {
                try stdout().print("\x1b[1;31mUnknown command: /{s}. Type '/help' for help.\x1b[0m\n", .{cmd});
            }
        }
    }
};
