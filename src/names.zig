const std = @import("std");

const SURNAMES = [_][]const u8{
    "艾",
    "爱",
    "安",
    "敖",
    "巴",
    "白",
    "柏",
    "班",
    "包",
    "薄",
    "鲍",
    "暴",
    "贝",
    "边",
    "卞",
    "蔡",
    "曹",
    "曾",
    "查",
    "柴",
    "昌",
    "巢",
    "车",
    "陈",
    "成",
    "程",
    "池",
    "迟",
    "充",
    "仇",
    "楚",
    "褚",
    "崔",
    "戴",
    "单",
    "淡",
    "澹台",
    "党",
    "德",
    "邓",
    "狄",
    "翟",
    "刁",
    "丁",
    "东方",
    "东郭",
    "董",
    "都",
    "豆",
    "窦",
    "独孤",
    "杜",
    "段",
    "樊",
    "范",
    "方",
    "房",
    "费",
    "封",
    "冯",
    "伏",
    "付",
    "傅",
    "富",
    "甘",
    "干",
    "高",
    "戈",
    "葛",
    "耿",
    "弓",
    "公",
    "公孙",
    "公冶",
    "宫",
    "龚",
    "巩",
    "贡",
    "勾",
    "苟",
    "古",
    "顾",
    "关",
    "官",
    "管",
    "龟",
    "桂",
    "郭",
    "国",
    "海",
    "韩",
    "杭",
    "郝",
    "何",
    "贺",
    "红",
    "洪",
    "侯",
    "后",
    "胡",
    "扈",
    "花",
    "华",
    "怀",
    "皇甫",
    "霍",
    "姬",
    "吉",
    "纪",
    "贾",
    "简",
    "江",
    "姜",
    "蒋",
    "焦",
    "竭",
    "解",
    "金",
    "晋",
    "经",
    "荆",
    "景",
    "康",
    "空",
    "孔",
    "寇",
    "匡",
    "来",
    "赖",
    "蓝",
    "郎",
    "雷",
    "冷",
    "黎",
    "李",
    "里",
    "理",
    "厉",
    "利",
    "荔",
    "连",
    "练",
    "良",
    "梁",
    "林",
    "蔺",
    "凌",
    "令狐",
    "刘",
    "柳",
    "龙",
    "娄",
    "楼",
    "卢",
    "鲁",
    "陆",
    "闾",
    "吕",
    "栾",
    "罗",
    "骆",
    "马",
    "满",
    "芒",
    "毛",
    "茅",
    "梅",
    "门",
    "孟",
    "米",
    "苗",
    "明",
    "莫",
    "牟",
    "缪",
    "慕容",
    "穆",
    "那",
    "年",
    "聂",
    "宁",
    "牛",
    "诺",
    "欧",
    "欧阳",
    "潘",
    "庞",
    "裴",
    "彭",
    "皮",
    "平",
    "蒲",
    "濮阳",
    "浦",
    "漆",
    "祁",
    "齐",
    "钱",
    "强",
    "秦",
    "琴",
    "青",
    "丘",
    "邱",
    "裘",
    "屈",
    "全",
    "权",
    "冉",
    "饶",
    "任",
    "荣",
    "容",
    "阮",
    "瑞",
    "桑",
    "沙",
    "山",
    "商",
    "上官",
    "尚",
    "邵",
    "申",
    "申屠",
    "沈",
    "盛",
    "施",
    "石",
    "史",
    "手",
    "寿",
    "舒",
    "帅",
    "舜",
    "司",
    "司空",
    "司寇",
    "司马",
    "司徒",
    "松",
    "宋",
    "苏",
    "隋",
    "孙",
    "太叔",
    "汤",
    "唐",
    "陶",
    "田",
    "铁",
    "佟",
    "童",
    "涂",
    "屠",
    "土",
    "托",
    "万",
    "万俟",
    "汪",
    "王",
    "危",
    "微",
    "卫",
    "尉迟",
    "魏",
    "温",
    "文",
    "闻",
    "闻人",
    "翁",
    "吴",
    "伍",
    "武",
    "昔",
    "夏",
    "鲜",
    "鲜于",
    "显",
    "向",
    "项",
    "萧",
    "辛",
    "邢",
    "熊",
    "胥",
    "徐",
    "许",
    "轩辕",
    "宣",
    "薛",
    "闫",
    "严",
    "言",
    "阎",
    "颜",
    "晏",
    "燕",
    "阳",
    "杨",
    "姚",
    "叶",
    "宜",
    "易",
    "益",
    "殷",
    "尹",
    "尤",
    "游",
    "于",
    "余",
    "虞",
    "宇文",
    "郁",
    "喻",
    "元",
    "原",
    "袁",
    "岳",
    "昝",
    "展",
    "张",
    "章",
    "长孙",
    "兆",
    "赵",
    "郑",
    "志",
    "钟",
    "钟离",
    "仲孙",
    "周",
    "朱",
    "诸",
    "诸葛",
    "祝",
    "梓",
    "子",
    "宗",
    "宗政",
    "邹",
    "祖",
    "左",
};

fn utf8DecodeAt(text: []const u8, i: usize) ?struct { cp: u21, len: usize } {
    if (i >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return null;
    if (i + len > text.len) return null;
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return null;
    return .{ .cp = cp, .len = len };
}

fn isCjkChar(cp: u21) bool {
    return (cp >= 0x4E00 and cp <= 0x9FFF) or
           (cp >= 0x3400 and cp <= 0x4DBF);
}

fn findLongestSurname(text: []const u8) usize {
    var surname_len: usize = 0;
    for (SURNAMES) |surname| {
        if (std.mem.startsWith(u8, text, surname)) {
            if (surname.len > surname_len) surname_len = surname.len;
        }
    }
    return surname_len;
}

fn tryMatchChineseNameLoose(text: []const u8, start: usize) ?usize {
    const surname_len = findLongestSurname(text[start..]);
    if (surname_len == 0) return null;

    // Must not be preceded by a CJK character
    if (start > 0) {
        var prev = start - 1;
        while (prev > 0 and (text[prev] & 0xC0) == 0x80) prev -= 1;
        if (utf8DecodeAt(text, prev)) |decoded| {
            if (isCjkChar(decoded.cp)) return null;
        }
    }

    var pos = start + surname_len;
    var given_name_chars: usize = 0;

    while (given_name_chars < 3) {
        const decoded = utf8DecodeAt(text, pos) orelse break;
        if (!isCjkChar(decoded.cp)) break;
        pos += decoded.len;
        given_name_chars += 1;
    }

    if (given_name_chars == 0) return null;

    return pos - start;
}

fn countCjkChars(allocator: std.mem.Allocator, html: []const u8, char_freq: *std.StringHashMap(usize)) !void {
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const tag_end = std.mem.indexOfPos(u8, html, i, ">") orelse {
                i += 1;
                continue;
            };
            i = tag_end + 1;
        } else {
            const text_end = std.mem.indexOfPos(u8, html, i, "<") orelse html.len;
            const text = html[i..text_end];

            var j: usize = 0;
            while (j < text.len) {
                const decoded = utf8DecodeAt(text, j) orelse {
                    j += 1;
                    continue;
                };
                if (isCjkChar(decoded.cp)) {
                    const ch = text[j .. j + decoded.len];
                    const existing = char_freq.get(ch);
                    if (existing) |count| {
                        try char_freq.put(ch, count + 1);
                    } else {
                        const key_copy = try allocator.dupe(u8, ch);
                        try char_freq.put(key_copy, 1);
                    }
                }
                j += decoded.len;
            }

            i = text_end;
        }
    }
}

fn collectCandidates(allocator: std.mem.Allocator, html: []const u8, candidates: *std.StringHashMap(usize)) !void {
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const tag_end = std.mem.indexOfPos(u8, html, i, ">") orelse {
                i += 1;
                continue;
            };
            i = tag_end + 1;
        } else {
            const text_end = std.mem.indexOfPos(u8, html, i, "<") orelse html.len;
            const text = html[i..text_end];

            var j: usize = 0;
            while (j < text.len) {
                const surname_len = findLongestSurname(text[j..]);
                if (surname_len == 0) {
                    j += 1;
                    continue;
                }

                // Must not be preceded by a CJK character
                if (j > 0) {
                    var prev = j - 1;
                    while (prev > 0 and (text[prev] & 0xC0) == 0x80) prev -= 1;
                    if (utf8DecodeAt(text, prev)) |decoded| {
                        if (isCjkChar(decoded.cp)) {
                            j += 1;
                            continue;
                        }
                    }
                }

                var pos = j + surname_len;
                var given_name_chars: usize = 0;

                while (given_name_chars < 3) {
                    const decoded = utf8DecodeAt(text, pos) orelse break;
                    if (!isCjkChar(decoded.cp)) break;
                    pos += decoded.len;
                    given_name_chars += 1;

                    const name = text[j..pos];
                    const existing = candidates.get(name);
                    if (existing) |count| {
                        try candidates.put(name, count + 1);
                    } else {
                        const key_copy = try allocator.dupe(u8, name);
                        try candidates.put(key_copy, 1);
                    }
                }

                j = pos; // advance by longest match
            }

            i = text_end;
        }
    }
}

fn minCharFreq(name: []const u8, char_freq: *std.StringHashMap(usize)) ?usize {
    var min_freq: usize = std.math.maxInt(usize);
    var k: usize = 0;
    var chars_seen: usize = 0;
    while (k < name.len) {
        const decoded = utf8DecodeAt(name, k) orelse break;
        const ch = name[k .. k + decoded.len];
        const freq = char_freq.get(ch) orelse 0;
        if (freq < min_freq) min_freq = freq;
        k += decoded.len;
        chars_seen += 1;
    }
    if (chars_seen == 0 or min_freq == 0 or min_freq == std.math.maxInt(usize)) return null;
    return min_freq;
}

pub const NameSet = std.StringHashMap(usize);

const NAME_OPEN_TAGS = [_][]const u8{
    "<name0>", "<name1>", "<name2>", "<name3>",
    "<name4>", "<name5>", "<name6>", "<name7>",
};
const NAME_CLOSE_TAGS = [_][]const u8{
    "</name0>", "</name1>", "</name2>", "</name3>",
    "</name4>", "</name5>", "</name6>", "</name7>",
};

fn addFilteredNames(
    allocator: std.mem.Allocator,
    candidates: *std.StringHashMap(usize),
    char_freq: *std.StringHashMap(usize),
    result: *NameSet,
) !void {
    const min_count = 2;
    const jaccard_threshold: f64 = 0.10;
    const char_ratio_threshold_3: f64 = 0.20;
    const char_ratio_threshold_4: f64 = 0.20;

    // Pass 1: 2-char names (Jaccard filter)
    var it = candidates.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const count = entry.value_ptr.*;
        if (name.len != 6 or count < min_count) continue;

        const f1 = char_freq.get(name[0..3]) orelse continue;
        const f2 = char_freq.get(name[3..6]) orelse continue;
        const union_size = f1 + f2 - count;
        if (union_size == 0) continue;
        const jaccard = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(union_size));
        if (jaccard < jaccard_threshold) continue;

        if (!result.contains(name)) {
            const key = try allocator.dupe(u8, name);
            try result.put(key, 0);
        }
    }

    // Pass 2: 3-char names (min-character ratio filter)
    it = candidates.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const count = entry.value_ptr.*;
        if (name.len != 9 or count < min_count) continue;

        const min_freq = minCharFreq(name, char_freq) orelse continue;
        const char_ratio = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(min_freq));
        if (char_ratio < char_ratio_threshold_3) continue;

        if (!result.contains(name)) {
            const key = try allocator.dupe(u8, name);
            try result.put(key, 0);
        }
    }

    // Pass 3: 4-char names (must have accepted 3-char prefix + min-character ratio)
    it = candidates.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const count = entry.value_ptr.*;
        if (name.len != 12 or count < min_count) continue;

        const prefix = name[0..9];
        if (!result.contains(prefix)) continue;

        const min_freq = minCharFreq(name, char_freq) orelse continue;
        const char_ratio = @as(f64, @floatFromInt(count)) / @as(f64, @floatFromInt(min_freq));
        if (char_ratio < char_ratio_threshold_4) continue;

        if (!result.contains(name)) {
            const key = try allocator.dupe(u8, name);
            try result.put(key, 0);
        }
    }
}

pub fn buildNameSetFromContents(allocator: std.mem.Allocator, contents: []const []const u8) !NameSet {
    var result = NameSet.init(allocator);

    for (contents) |content| {
        if (content.len == 0) continue;

        var candidates = std.StringHashMap(usize).init(allocator);
        defer {
            var it = candidates.keyIterator();
            while (it.next()) |key| allocator.free(key.*);
            candidates.deinit();
        }

        var char_freq = std.StringHashMap(usize).init(allocator);
        defer {
            var it = char_freq.keyIterator();
            while (it.next()) |key| allocator.free(key.*);
            char_freq.deinit();
        }

        try countCjkChars(allocator, content, &char_freq);
        try collectCandidates(allocator, content, &candidates);
        try addFilteredNames(allocator, &candidates, &char_freq, &result);
    }

    // Assign colors (0-7) to each detected name
    var color_idx: usize = 0;
    var color_it = result.iterator();
    while (color_it.next()) |entry| {
        entry.value_ptr.* = color_idx % 8;
        color_idx += 1;
    }

    return result;
}

pub fn buildNameSet(allocator: std.mem.Allocator, epub: anytype) !NameSet {
    var contents = std.array_list.Managed([]const u8).init(allocator);
    defer contents.deinit();
    for (0..epub.chapters.items.len) |i| {
        const content = try epub.getChapterContent(i);
        try contents.append(content orelse "");
    }
    return buildNameSetFromContents(allocator, contents.items);
}

pub fn deinitNameSet(set: *NameSet, allocator: std.mem.Allocator) void {
    var it = set.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
    set.deinit();
}

pub fn injectNameTags(allocator: std.mem.Allocator, html: []const u8, name_set: ?NameSet) ![]u8 {
    var marked = std.array_list.Managed(u8).init(allocator);
    defer marked.deinit();

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
                if (name_set) |set| {
                    // Check if any known name starts at this position (prefer longest)
                    var longest_match_len: ?usize = null;
                    var longest_match_color: usize = 0;
                    var it = set.iterator();
                    while (it.next()) |entry| {
                        const name = entry.key_ptr.*;
                        if (std.mem.startsWith(u8, text[j..], name)) {
                            if (longest_match_len == null or name.len > longest_match_len.?) {
                                longest_match_len = name.len;
                                longest_match_color = entry.value_ptr.*;
                            }
                        }
                    }
                    if (longest_match_len) |name_len| {
                        try marked.appendSlice(NAME_OPEN_TAGS[longest_match_color]);
                        try marked.appendSlice(text[j .. j + name_len]);
                        try marked.appendSlice(NAME_CLOSE_TAGS[longest_match_color]);
                        j += name_len;
                        continue;
                    }
                } else {
                    if (tryMatchChineseNameLoose(text, j)) |name_len| {
                        try marked.appendSlice(NAME_OPEN_TAGS[0]);
                        try marked.appendSlice(text[j .. j + name_len]);
                        try marked.appendSlice(NAME_CLOSE_TAGS[0]);
                        j += name_len;
                        continue;
                    }
                }
                try marked.append(text[j]);
                j += 1;
            }

            i = text_end;
        }
    }

    return marked.toOwnedSlice();
}
