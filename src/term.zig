const std = @import("std");
const posix = std.posix;

pub const TermSize = struct {
    rows: u16,
    cols: u16,
};

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    escape,
    unknown,
};

const winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

pub fn getTerminalSize() !TermSize {
    const TIOCGWINSZ: u32 = 0x40087468;
    var ws: winsize = undefined;
    const rc = posix.system.ioctl(std.fs.File.stdout().handle, TIOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return error.IoctlFailed;
    return .{ .rows = ws.ws_row, .cols = ws.ws_col };
}

var saved_termios: ?posix.termios = null;

pub fn enableRawMode() !void {
    const fd = std.fs.File.stdin().handle;
    const termios = try posix.tcgetattr(fd);
    saved_termios = termios;

    var raw = termios;
    raw.iflag.ICRNL = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    try posix.tcsetattr(fd, .NOW, raw);
}

pub fn disableRawMode() void {
    if (saved_termios) |termios| {
        const fd = std.fs.File.stdin().handle;
        posix.tcsetattr(fd, .NOW, termios) catch {};
        saved_termios = null;
    }
}

pub fn readKey() !Key {
    const stdin = std.fs.File.stdin();
    var buf: [1]u8 = undefined;
    const n = try stdin.read(&buf);
    if (n == 0) return error.EndOfStream;

    const b = buf[0];
    if (b != '\x1b') return .{ .char = b };

    // Temporarily set timeout for escape sequence reading
    const fd = stdin.handle;
    var termios = try posix.tcgetattr(fd);
    const saved = termios;
    termios.cc[@intFromEnum(posix.V.MIN)] = 0;
    termios.cc[@intFromEnum(posix.V.TIME)] = 1; // 0.1s timeout
    try posix.tcsetattr(fd, .NOW, termios);
    defer posix.tcsetattr(fd, .NOW, saved) catch {};

    // Try to read '['
    const n1 = stdin.read(&buf) catch 0;
    if (n1 == 0 or buf[0] != '[') return .escape;

    // Try to read the code
    const n2 = stdin.read(&buf) catch 0;
    if (n2 == 0) return .escape;

    return switch (buf[0]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        '5' => {
            _ = stdin.read(&buf) catch 0;
            return .page_up;
        },
        '6' => {
            _ = stdin.read(&buf) catch 0;
            return .page_down;
        },
        else => .unknown,
    };
}
