const std = @import("std");
const Epub = @import("epub.zig").Epub;
const html = @import("html.zig");
const names = @import("names.zig");
const term = @import("term.zig");

pub const Repl = struct {
    allocator: std.mem.Allocator,
    epub: ?*Epub,
    current_chapter: usize,
    running: bool,
    last_search: ?[]const u8,
    search_mode: SearchMode,
    name_highlight: bool,
    name_set: ?names.NameSet,

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
        };
    }

    pub fn deinit(self: *Repl) void {
        if (self.last_search) |s| self.allocator.free(s);
        if (self.name_set) |*set| {
            names.deinitNameSet(set, self.allocator);
        }
    }

    fn stdout() std.fs.File.DeprecatedWriter {
        return std.fs.File.stdout().deprecatedWriter();
    }

    pub fn run(self: *Repl, epub: *Epub) !void {
        self.epub = epub;
        self.current_chapter = 0;

        try self.printWelcome();
        try self.showToc();

        var buf: [1024]u8 = undefined;
        while (self.running) {
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

            try stdout().writeAll("\x1b[2J\x1b[H");

            const end = @min(top + visible_lines, lines.items.len);
            for (lines.items[top..end]) |line| {
                try stdout().print("{s}\n", .{line});
            }

            try stdout().print("\x1b[7m-- {d}/{d} -- [j/k/u/d/g/G/q] --\x1b[0m", .{
                top + 1,
                lines.items.len,
            });

            const key = term.readKey() catch break;
            switch (key) {
                .char => |c| switch (c) {
                    'q', 'Q' => break,
                    'j', 'J', '\r', ' ' => {
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
        try self.showCurrentChapter();
    }

    fn nextChapter(self: *Repl) !void {
        if (self.epub == null) return;
        if (self.current_chapter + 1 >= self.epub.?.chapters.items.len) {
            try stdout().print("\x1b[1;33mAlready at the last chapter.\x1b[0m\n", .{});
            return;
        }
        self.current_chapter += 1;
        try self.showCurrentChapter();
    }

    fn prevChapter(self: *Repl) !void {
        if (self.current_chapter == 0) {
            try stdout().print("\x1b[1;33mAlready at the first chapter.\x1b[0m\n", .{});
            return;
        }
        self.current_chapter -= 1;
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
            self.running = false;
            try stdout().print("\x1b[1;33mGoodbye! 👋\x1b[0m\n", .{});
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "?")) {
            try self.showHelp();
        } else if (std.mem.eql(u8, cmd, "toc") or std.mem.eql(u8, cmd, "ls")) {
            try self.showToc();
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
            if (self.name_set == null and self.epub != null) {
                try stdout().print("\x1b[2mScanning book for recurring names...\x1b[0m\n", .{});
                self.name_set = try names.buildNameSet(self.allocator, self.epub.?);
                try stdout().print("\x1b[2mDone.\x1b[0m\n", .{});
            }
            self.name_highlight = !self.name_highlight;
            const status = if (self.name_highlight) "\x1b[1;32mon\x1b[0m" else "\x1b[1;31moff\x1b[0m";
            try stdout().print("Name highlighting: {s}\n", .{status});
            if (self.name_highlight) try self.showCurrentChapter();
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
