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

    fn runPager(self: *Repl, text: []const u8) !void {
        const size = term.getTerminalSize() catch {
            try stdout().print("{s}\n", .{text});
            return;
        };

        var lines = std.array_list.Managed([]const u8).init(self.allocator);
        defer lines.deinit();

        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            try lines.append(line);
        }
        if (lines.items.len == 0) return;

        term.enableRawMode() catch {
            try stdout().print("{s}\n", .{text});
            return;
        };
        defer term.disableRawMode();

        var top: usize = 0;

        while (true) {
            const current_size = term.getTerminalSize() catch size;
            const visible_lines = if (current_size.rows > 1) current_size.rows - 1 else current_size.rows;
            const cols = if (current_size.cols > 0) current_size.cols else 80;

            try stdout().writeAll("\x1b[2J\x1b[H");

            var phys_rows: usize = 0;
            for (lines.items[top..]) |line| {
                const w = lineDisplayWidth(line);
                const line_rows = if (w == 0) 1 else (w + cols - 1) / cols;
                if (phys_rows + line_rows > visible_lines) break;
                try stdout().print("{s}\n", .{line});
                phys_rows += line_rows;
            }

            try stdout().print("\x1b[7m-- {d}/{d} -- [j/k/u/d/g/G/q] --\x1b[0m", .{
                top + 1,
                lines.items.len,
            });

            const key = term.readKey() catch break;
            switch (key) {
                .char => |c| switch (c) {
                    'q', 'Q' => break,
                    'j', 'J', '\r', '\n', ' ' => {
                        if (top + 1 < lines.items.len) top += 1;
                    },
                    'k', 'K' => {
                        if (top > 0) top -= 1;
                    },
                    'd', 'D' => {
                        const half = visible_lines / 2;
                        const new_top = top + half;
                        top = if (new_top >= lines.items.len) lines.items.len - 1 else new_top;
                    },
                    'u', 'U' => {
                        const half = visible_lines / 2;
                        top = if (top > half) top - half else 0;
                    },
                    'g' => top = 0,
                    'G' => {
                        top = if (lines.items.len > visible_lines) lines.items.len - visible_lines else 0;
                    },
                    else => {},
                },
                .up => {
                    if (top > 0) top -= 1;
                },
                .down => {
                    if (top + 1 < lines.items.len) top += 1;
                },
                .page_up => {
                    const half = visible_lines / 2;
                    top = if (top > half) top - half else 0;
                },
                .page_down => {
                    const half = visible_lines / 2;
                    const new_top = top + half;
                    top = if (new_top >= lines.items.len) lines.items.len - 1 else new_top;
                },
                .home => top = 0,
                .end => {
                    top = if (lines.items.len > visible_lines) lines.items.len - visible_lines else 0;
                },
                .escape => break,
                else => {},
            }
        }

        try stdout().writeAll("\n");
    }

    fn showCurrentChapter(self: *Repl) !void {
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

        try self.runPager(full_text);
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
