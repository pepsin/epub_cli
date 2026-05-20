const std = @import("std");
const names = @import("names.zig");

pub const injectNameTags = names.injectNameTags;

const ANSI_RESET = "\x1b[0m";
const ANSI_BOLD = "\x1b[1m";
const ANSI_DIM = "\x1b[2m";
const ANSI_ITALIC = "\x1b[3m";
const ANSI_UNDERLINE = "\x1b[4m";
const ANSI_BLINK = "\x1b[5m";
const ANSI_REVERSE = "\x1b[7m";
const ANSI_STRIKETHROUGH = "\x1b[9m";

const ANSI_BLACK = "\x1b[30m";
const ANSI_RED = "\x1b[31m";
const ANSI_GREEN = "\x1b[32m";
const ANSI_YELLOW = "\x1b[33m";
const ANSI_BLUE = "\x1b[34m";
const ANSI_MAGENTA = "\x1b[35m";
const ANSI_CYAN = "\x1b[36m";
const ANSI_WHITE = "\x1b[37m";

const ANSI_BG_BLACK = "\x1b[40m";
const ANSI_BG_RED = "\x1b[41m";
const ANSI_BG_GREEN = "\x1b[42m";
const ANSI_BG_YELLOW = "\x1b[43m";
const ANSI_BG_BLUE = "\x1b[44m";
const ANSI_BG_MAGENTA = "\x1b[45m";
const ANSI_BG_CYAN = "\x1b[46m";
const ANSI_BG_WHITE = "\x1b[47m";
const ANSI_NAME = ANSI_BOLD ++ ANSI_MAGENTA;

const TagStyle = struct {
    open: []const u8,
    close: bool = true,
};

fn getTagStyle(tag: []const u8) ?TagStyle {
    var buf: [64]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, tag);
    const t = std.mem.trim(u8, lower, " \t\r\n");

    if (std.mem.eql(u8, t, "h1")) return .{ .open = ANSI_BOLD ++ ANSI_YELLOW };
    if (std.mem.eql(u8, t, "h2")) return .{ .open = ANSI_BOLD ++ ANSI_GREEN };
    if (std.mem.eql(u8, t, "h3")) return .{ .open = ANSI_BOLD ++ ANSI_CYAN };
    if (std.mem.eql(u8, t, "h4")) return .{ .open = ANSI_BOLD ++ ANSI_BLUE };
    if (std.mem.eql(u8, t, "h5")) return .{ .open = ANSI_BOLD ++ ANSI_MAGENTA };
    if (std.mem.eql(u8, t, "h6")) return .{ .open = ANSI_BOLD ++ ANSI_WHITE };
    if (std.mem.eql(u8, t, "b") or std.mem.eql(u8, t, "strong")) return .{ .open = ANSI_BOLD };
    if (std.mem.eql(u8, t, "i") or std.mem.eql(u8, t, "em") or std.mem.eql(u8, t, "cite")) return .{ .open = ANSI_ITALIC };
    if (std.mem.eql(u8, t, "u")) return .{ .open = ANSI_UNDERLINE };
    if (std.mem.eql(u8, t, "s") or std.mem.eql(u8, t, "strike")) return .{ .open = ANSI_STRIKETHROUGH };
    if (std.mem.eql(u8, t, "a")) return .{ .open = ANSI_UNDERLINE ++ ANSI_BLUE };
    if (std.mem.eql(u8, t, "code")) return .{ .open = ANSI_BG_BLACK ++ ANSI_CYAN };
    if (std.mem.eql(u8, t, "pre")) return .{ .open = ANSI_BG_BLACK };
    if (std.mem.eql(u8, t, "mark")) return .{ .open = ANSI_BG_YELLOW ++ ANSI_BLACK };
    if (std.mem.eql(u8, t, "blockquote")) return .{ .open = ANSI_DIM };
    if (std.mem.eql(u8, t, "sup")) return .{ .open = ANSI_BOLD };
    if (std.mem.eql(u8, t, "sub")) return .{ .open = ANSI_DIM };

    // Highlight search matches - special handling
    if (std.mem.eql(u8, t, "search-match")) return .{ .open = ANSI_BG_YELLOW ++ ANSI_BLACK ++ ANSI_BOLD };
    if (std.mem.eql(u8, t, "name")) return .{ .open = ANSI_NAME };

    return null;
}

fn isBlockTag(tag: []const u8) bool {
    const block_tags = [_][]const u8{
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "li", "tr", "td", "th",
        "section", "article", "nav", "aside", "header", "footer",
        "br", "hr",
    };
    var buf: [64]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, tag);
    for (block_tags) |bt| {
        if (std.mem.startsWith(u8, lower, bt)) return true;
    }
    return false;
}

fn isIgnoredTag(tag: []const u8) bool {
    const ignored = [_][]const u8{
        "script", "style", "svg", "math", "video", "audio", "canvas",
        "iframe", "embed", "object", "param", "source", "track",
    };
    var buf: [64]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, tag);
    for (ignored) |ig| {
        if (std.mem.startsWith(u8, lower, ig)) return true;
    }
    return false;
}

fn htmlUnescape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            if (std.mem.startsWith(u8, text[i..], "&amp;")) {
                try result.append('&');
                i += 5;
            } else if (std.mem.startsWith(u8, text[i..], "&lt;")) {
                try result.append('<');
                i += 4;
            } else if (std.mem.startsWith(u8, text[i..], "&gt;")) {
                try result.append('>');
                i += 4;
            } else if (std.mem.startsWith(u8, text[i..], "&quot;")) {
                try result.append('"');
                i += 6;
            } else if (std.mem.startsWith(u8, text[i..], "&apos;")) {
                try result.append('\'');
                i += 6;
            } else if (std.mem.startsWith(u8, text[i..], "&#")) {
                const end = std.mem.indexOfPos(u8, text, i, ";") orelse i + 1;
                const num_str = text[i + 2 .. end];
                const codepoint = if (num_str.len > 0 and num_str[0] == 'x')
                    std.fmt.parseInt(u21, num_str[1..], 16) catch 0
                else
                    std.fmt.parseInt(u21, num_str, 10) catch 0;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buf) catch 0;
                try result.appendSlice(buf[0..len]);
                i = end + 1;
            } else if (std.mem.startsWith(u8, text[i..], "&nbsp;")) {
                try result.append(' ');
                i += 6;
            } else if (std.mem.startsWith(u8, text[i..], "&mdash;")) {
                try result.appendSlice("—");
                i += 7;
            } else if (std.mem.startsWith(u8, text[i..], "&ndash;")) {
                try result.appendSlice("–");
                i += 7;
            } else if (std.mem.startsWith(u8, text[i..], "&hellip;")) {
                try result.appendSlice("…");
                i += 8;
            } else if (std.mem.startsWith(u8, text[i..], "&ldquo;")) {
                try result.appendSlice("\"");
                i += 7;
            } else if (std.mem.startsWith(u8, text[i..], "&rdquo;")) {
                try result.appendSlice("\"");
                i += 7;
            } else if (std.mem.startsWith(u8, text[i..], "&lsquo;")) {
                try result.appendSlice("'");
                i += 7;
            } else if (std.mem.startsWith(u8, text[i..], "&rsquo;")) {
                try result.appendSlice("'");
                i += 7;
            } else {
                try result.append(text[i]);
                i += 1;
            }
        } else {
            try result.append(text[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

pub fn renderToTerminal(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();

    var style_stack: [32][]const u8 = undefined;
    var stack_depth: usize = 0;
    var ignore_depth: usize = 0;
    var last_was_block: bool = true;

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const tag_end = std.mem.indexOfPos(u8, html, i, ">") orelse {
                i += 1;
                continue;
            };
            var tag = html[i + 1 .. tag_end];
            const is_close = std.mem.startsWith(u8, tag, "/");
            if (is_close) tag = tag[1..];

            // Extract just the tag name (before any attributes)
            const space_idx = std.mem.indexOfAny(u8, tag, " \t\r\n");
            const tag_name = if (space_idx) |si| tag[0..si] else tag;

            if (isIgnoredTag(tag_name)) {
                if (is_close) {
                    if (ignore_depth > 0) ignore_depth -= 1;
                } else {
                    ignore_depth += 1;
                }
                i = tag_end + 1;
                continue;
            }

            if (ignore_depth > 0) {
                i = tag_end + 1;
                continue;
            }

            if (isBlockTag(tag_name)) {
                if (!last_was_block) {
                    try output.append('\n');
                }
                last_was_block = true;
            }

            if (is_close) {
                if (stack_depth > 0) {
                    stack_depth -= 1;
                    try output.appendSlice(ANSI_RESET);
                    // Re-apply parent styles
                    var j: usize = 0;
                    while (j < stack_depth) : (j += 1) {
                        try output.appendSlice(style_stack[j]);
                    }
                }
            } else {
                if (getTagStyle(tag_name)) |style| {
                    if (stack_depth < style_stack.len) {
                        style_stack[stack_depth] = style.open;
                        stack_depth += 1;
                        try output.appendSlice(style.open);
                    }
                }
            }

            i = tag_end + 1;
        } else {
            if (ignore_depth > 0) {
                i += 1;
                continue;
            }

            // Skip extra whitespace after block elements
            if (last_was_block and (html[i] == ' ' or html[i] == '\t' or html[i] == '\n' or html[i] == '\r')) {
                i += 1;
                continue;
            }
            last_was_block = false;

            // Collect text until next tag
            const text_start = i;
            while (i < html.len and html[i] != '<') : (i += 1) {}
            const text = html[text_start..i];

            // Collapse whitespace
            var j: usize = 0;
            while (j < text.len) {
                if (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r') {
                    try output.append(' ');
                    j += 1;
                    while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r')) {
                        j += 1;
                    }
                } else {
                    try output.append(text[j]);
                    j += 1;
                }
            }
        }
    }

    // Unescape HTML entities
    const result = try output.toOwnedSlice();
    defer allocator.free(result);
    return htmlUnescape(allocator, result);
}

pub fn renderWithSearchHighlight(
    allocator: std.mem.Allocator,
    html: []const u8,
    search_term: []const u8,
) ![]u8 {
    // Simple approach: wrap search matches in a special tag before rendering
    var marked = std.array_list.Managed(u8).init(allocator);
    defer marked.deinit();

    const lower_term = try std.ascii.allocLowerString(allocator, search_term);
    defer allocator.free(lower_term);

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const tag_end = std.mem.indexOfPos(u8, html, i, ">") orelse {
                try marked.append(html[i]);
                i += 1;
                continue;
            };
            try marked.appendSlice(html[i .. tag_end + 1]);
            i = tag_end + 1;
        } else {
            const text_end = std.mem.indexOfPos(u8, html, i, "<") orelse html.len;
            const text = html[i..text_end];

            var j: usize = 0;
            while (j < text.len) {
                const remaining = text[j..];
                const lower_remaining = try std.ascii.allocLowerString(allocator, remaining);
                defer allocator.free(lower_remaining);

                if (std.mem.indexOf(u8, lower_remaining, lower_term)) |match| {
                    try marked.appendSlice(text[j .. j + match]);
                    try marked.appendSlice("<search-match>");
                    try marked.appendSlice(text[j + match .. j + match + search_term.len]);
                    try marked.appendSlice("</search-match>");
                    j += match + search_term.len;
                } else {
                    try marked.appendSlice(text[j..]);
                    break;
                }
            }

            i = text_end;
        }
    }

    return renderToTerminal(allocator, marked.items);
}
