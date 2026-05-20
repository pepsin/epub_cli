const std = @import("std");
const Epub = @import("epub.zig").Epub;
const html = @import("html.zig");

pub const Repl = struct {
    allocator: std.mem.Allocator,
    epub: ?*Epub,
    current_chapter: usize,
    running: bool,
    last_search: ?[]const u8,
    search_mode: SearchMode,

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
        };
    }

    pub fn deinit(self: *Repl) void {
        if (self.last_search) |s| self.allocator.free(s);
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

        try stdout().print("\n", .{});
        try stdout().print("\x1b[1;35m╔══════════════════════════════════════════════════════════════╗\x1b[0m\n", .{});
        try stdout().print("\x1b[1;35m║  Chapter {d}/{d}: {s}\x1b[0m\n", .{
            self.current_chapter + 1,
            e.chapters.items.len,
            ch.title,
        });
        try stdout().print("\x1b[1;35m╚══════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});
        try stdout().print("\n", .{});

        const rendered = if (self.last_search) |term|
            try html.renderWithSearchHighlight(self.allocator, raw_content.?, term)
        else
            try html.renderToTerminal(self.allocator, raw_content.?);
        defer self.allocator.free(rendered);

        try stdout().print("{s}\n", .{rendered});
        try stdout().print("\n", .{});
        try stdout().print("\x1b[2m── End of Chapter {d}/{d} ──\x1b[0m\n", .{
            self.current_chapter + 1,
            e.chapters.items.len,
        });
        try stdout().print("\n", .{});
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
                try stdout().print("Use \x1b[1mgo <number>\x1b[0m to navigate to a chapter.\n", .{});
            } else {
                try stdout().print("\x1b[1;33mNo matches found.\x1b[0m\n", .{});
            }
        }
        try stdout().print("\n", .{});
    }

    fn showHelp(_: *Repl) !void {
        try stdout().print("\n", .{});
        try stdout().print("\x1b[1;33m┌────────── Commands ──────────┐\x1b[0m\n", .{});
        try stdout().print("\x1b[1m  toc, ls     \x1b[0m Show table of contents\n", .{});
        try stdout().print("\x1b[1m  go <n>      \x1b[0m Go to chapter n\n", .{});
        try stdout().print("\x1b[1m  next, n     \x1b[0m Next chapter\n", .{});
        try stdout().print("\x1b[1m  prev, p     \x1b[0m Previous chapter\n", .{});
        try stdout().print("\x1b[1m  show, cat   \x1b[0m Show current chapter\n", .{});
        try stdout().print("\x1b[1m  search, /   \x1b[0m Search current chapter\n", .{});
        try stdout().print("\x1b[1m  search-all  \x1b[0m Search all chapters\n", .{});
        try stdout().print("\x1b[1m  clear, cls  \x1b[0m Clear screen\n", .{});
        try stdout().print("\x1b[1m  info        \x1b[0m Show book info\n", .{});
        try stdout().print("\x1b[1m  help, h, ?  \x1b[0m Show this help\n", .{});
        try stdout().print("\x1b[1m  quit, q     \x1b[0m Exit reader\n", .{});
        try stdout().print("\x1b[1;33m└──────────────────────────────┘\x1b[0m\n", .{});
        try stdout().print("\n", .{});
    }

    fn handleCommand(self: *Repl, cmd_line: []const u8) !void {
        var parts = std.mem.splitScalar(u8, cmd_line, ' ');
        const cmd = parts.next().?;
        const rest = std.mem.trim(u8, cmd_line[cmd.len..], " \t\r\n");

        if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "exit")) {
            self.running = false;
            try stdout().print("\x1b[1;33mGoodbye! 👋\x1b[0m\n", .{});
        } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "?")) {
            try self.showHelp();
        } else if (std.mem.eql(u8, cmd, "toc") or std.mem.eql(u8, cmd, "ls")) {
            try self.showToc();
        } else if (std.mem.eql(u8, cmd, "go") or std.mem.eql(u8, cmd, "cd") or std.mem.eql(u8, cmd, "goto")) {
            if (rest.len == 0) {
                try stdout().print("\x1b[1;31mUsage: go <chapter-number>\x1b[0m\n", .{});
                return;
            }
            try self.goToChapter(rest);
        } else if (std.mem.eql(u8, cmd, "next") or std.mem.eql(u8, cmd, "n")) {
            try self.nextChapter();
        } else if (std.mem.eql(u8, cmd, "prev") or std.mem.eql(u8, cmd, "p")) {
            try self.prevChapter();
        } else if (std.mem.eql(u8, cmd, "show") or std.mem.eql(u8, cmd, "cat") or std.mem.eql(u8, cmd, "read")) {
            try self.showCurrentChapter();
        } else if (std.mem.eql(u8, cmd, "search") or std.mem.eql(u8, cmd, "/") or std.mem.eql(u8, cmd, "find")) {
            self.search_mode = .current_chapter;
            try self.doSearch(rest);
        } else if (std.mem.eql(u8, cmd, "search-all") or std.mem.eql(u8, cmd, "find-all") or std.mem.eql(u8, cmd, "/?")) {
            self.search_mode = .all_chapters;
            try self.doSearch(rest);
        } else if (std.mem.eql(u8, cmd, "clear") or std.mem.eql(u8, cmd, "cls")) {
            try stdout().writeAll("\x1b[2J\x1b[H");
        } else if (std.mem.eql(u8, cmd, "info")) {
            try self.printWelcome();
        } else if (std.mem.eql(u8, cmd, "chapter") or std.mem.eql(u8, cmd, "ch")) {
            try stdout().print("\x1b[1;36mCurrent chapter: {d}/{d}\x1b[0m\n", .{
                self.current_chapter + 1,
                self.epub.?.chapters.items.len,
            });
        } else {
            // Try to parse as chapter number directly
            if (std.fmt.parseInt(usize, cmd, 10)) |_| {
                try self.goToChapter(cmd);
            } else |_| {
                try stdout().print("\x1b[1;31mUnknown command: {s}. Type 'help' for commands.\x1b[0m\n", .{cmd});
            }
        }
    }
};
