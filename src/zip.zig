const std = @import("std");

pub const FileEntry = struct {
    name: []const u8,
    compressed_size: u32,
    uncompressed_size: u32,
    compression_method: u16,
    local_header_offset: u32,
    crc32: u32,
};

pub const ZipReader = struct {
    allocator: std.mem.Allocator,
    data: []const u8,
    entries: std.array_list.Managed(FileEntry),

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !ZipReader {
        var reader = ZipReader{
            .allocator = allocator,
            .data = data,
            .entries = std.array_list.Managed(FileEntry).init(allocator),
        };
        try reader.readCentralDirectory();
        return reader;
    }

    pub fn deinit(self: *ZipReader) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        self.entries.deinit();
    }

    fn readCentralDirectory(self: *ZipReader) !void {
        if (self.data.len < 22) return error.InvalidZip;

        var eocd_offset: usize = 0;
        var i: usize = self.data.len - 22;
        while (i > 0) : (i -= 1) {
            if (std.mem.readInt(u32, self.data[i..][0..4], .little) == 0x06054b50) {
                eocd_offset = i;
                break;
            }
        }

        if (eocd_offset == 0) return error.InvalidZip;

        const cd_size = std.mem.readInt(u32, self.data[eocd_offset + 12 ..][0..4], .little);
        const cd_offset = std.mem.readInt(u32, self.data[eocd_offset + 16 ..][0..4], .little);

        if (cd_offset + cd_size > self.data.len) return error.InvalidZip;

        var offset: usize = cd_offset;
        const cd_end = cd_offset + cd_size;

        while (offset + 46 <= cd_end) {
            const sig = std.mem.readInt(u32, self.data[offset..][0..4], .little);
            if (sig != 0x02014b50) break;

            const compression_method = std.mem.readInt(u16, self.data[offset + 10 ..][0..2], .little);
            const compressed_size = std.mem.readInt(u32, self.data[offset + 20 ..][0..4], .little);
            const uncompressed_size = std.mem.readInt(u32, self.data[offset + 24 ..][0..4], .little);
            const name_len = std.mem.readInt(u16, self.data[offset + 28 ..][0..2], .little);
            const extra_len = std.mem.readInt(u16, self.data[offset + 30 ..][0..2], .little);
            const comment_len = std.mem.readInt(u16, self.data[offset + 32 ..][0..2], .little);
            const local_header_offset = std.mem.readInt(u32, self.data[offset + 42 ..][0..4], .little);
            const crc = std.mem.readInt(u32, self.data[offset + 16 ..][0..4], .little);

            if (offset + 46 + name_len + extra_len + comment_len > cd_end) break;

            const name = self.data[offset + 46 .. offset + 46 + name_len];
            const name_copy = try self.allocator.dupe(u8, name);

            try self.entries.append(.{
                .name = name_copy,
                .compressed_size = compressed_size,
                .uncompressed_size = uncompressed_size,
                .compression_method = compression_method,
                .local_header_offset = local_header_offset,
                .crc32 = crc,
            });

            offset += 46 + name_len + extra_len + comment_len;
        }
    }

    pub fn readFile(self: *ZipReader, entry: FileEntry) ![]u8 {
        const offset = entry.local_header_offset;
        if (offset + 30 > self.data.len) return error.InvalidZip;

        const name_len = std.mem.readInt(u16, self.data[offset + 26 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, self.data[offset + 28 ..][0..2], .little);
        const data_offset = offset + 30 + name_len + extra_len;

        if (data_offset + entry.compressed_size > self.data.len) return error.InvalidZip;

        const compressed_data = self.data[data_offset .. data_offset + entry.compressed_size];

        if (entry.compression_method == 0) {
            return self.allocator.dupe(u8, compressed_data);
        } else if (entry.compression_method == 8) {
            var in: std.Io.Reader = .fixed(compressed_data);
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();

            var decompress: std.compress.flate.Decompress = .init(&in, .raw, &.{});
            const decompressed_len = try decompress.reader.streamRemaining(&aw.writer);

            const result = try self.allocator.alloc(u8, decompressed_len);
            @memcpy(result, aw.written());
            return result;
        } else {
            return error.UnsupportedCompression;
        }
    }

    pub fn findEntry(self: *ZipReader, name: []const u8) ?FileEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }
};
