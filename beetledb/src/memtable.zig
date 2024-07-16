const std = @import("std");
const fs = std.fs;

const testing = std.testing;

// const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const Data = struct {
    num: u16,
    str: []const u8,

    pub fn serialize(self: *Data, allocator: *std.mem.Allocator) ![]u8 {
        const buf_len = @sizeOf(u16) + @sizeOf(u16) + self.str.len;
        const buf = try allocator.alloc(u8, buf_len);
        errdefer allocator.free(buf);

        // Create a writer for the buffer

        var stream = std.io.fixedBufferStream(buf);
        var writer = stream.writer();

        try writer.writeInt(u16, self.num, std.builtin.Endian.little);
        try writer.writeInt(u16, @intCast(self.str.len), std.builtin.Endian.little);
        try writer.writeAll(self.str);

        return buf;
    }
};

pub const Writer = struct {
    file: fs.File,
    allocator: *Allocator,

    pub fn open(allocator: *Allocator, filename: []const u8) !Writer {
        const file = try fs.cwd().createFile(filename, .{ .truncate = true });
        return Writer{ .file = file, .allocator = allocator };
    }

    pub fn write(self: *Writer, data: *Data) !void {
        const writer = self.file.writer();
        const serialized = try data.serialize(self.allocator);

        errdefer self.allocator.free(serialized);

        _ = try writer.write(serialized);
        try self.file.sync();
    }

    pub fn close(self: *Writer) void {
        self.file.close();
    }
};
