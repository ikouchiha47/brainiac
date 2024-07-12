const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const io = std.io;
const ArrayList = std.ArrayList;

const WAL = struct {
    file: fs.File,
    allocator: std.mem.Allocator,
    buffer: ArrayList(u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, filename: []const u8) !Self {
        const file = try fs.cwd().createFile(filename, .{ .read = true, .truncate = false, .append = true });
        const buffer = ArrayList(u8).init(allocator);
        return Self{
            .file = file,
            .allocator = allocator,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *Self) void {
        self.file.close();
        self.buffer.deinit();
    }

    pub fn writeEntry(self: *Self, entry: []const u8) !void {
        try self.buffer.appendSlice(entry);
        try self.buffer.append('\n');

        if (self.buffer.items.len >= 4096) {
            try self.flush();
        }
    }

    pub fn flush(self: *Self) !void {
        try self.file.writeAll(self.buffer.items);
        self.buffer.clearRetainingCapacity();
        try self.file.sync();
    }

    pub fn readEntries(self: *Self) !ArrayList([]const u8) {
        var entries = ArrayList([]const u8).init(self.allocator);
        try self.file.seekTo(0);

        var buf_reader = io.bufferedReader(self.file.reader());
        var in_stream = buf_reader.reader();

        while (try in_stream.readUntilDelimiterOrEofAlloc(self.allocator, '\n', 1024)) |line| {
            try entries.append(line);
        }

        return entries;
    }

    pub fn checkpoint(self: *Self) !void {
        // write the current state to the main database
        // and truncate the WAL.
        try self.flush();
        try self.file.setEndPos(0);
        try self.file.sync();
    }
};

test "WAL basic operations" {
    const test_filename = "test_wal.log";
    defer fs.cwd().deleteFile(test_filename) catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var wal = try WAL.init(allocator, test_filename);
    defer wal.deinit();

    // Test writing entries
    try wal.writeEntry("Entry 1");
    try wal.writeEntry("Entry 2");
    try wal.writeEntry("Entry 3");

    // Test flushing
    try wal.flush();

    // Test reading entries
    var entries = try wal.readEntries();
    defer entries.deinit();

    try testing.expectEqual(@as(usize, 3), entries.items.len);
    try testing.expectEqualStrings("Entry 1", entries.items[0]);
    try testing.expectEqualStrings("Entry 2", entries.items[1]);
    try testing.expectEqualStrings("Entry 3", entries.items[2]);

    // Test checkpointing
    try wal.checkpoint();

    entries = try wal.readEntries();
    defer entries.deinit();
    try testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "WAL large write" {
    const test_filename = "test_wal_large.log";
    defer fs.cwd().deleteFile(test_filename) catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var wal = try WAL.init(allocator, test_filename);
    defer wal.deinit();

    // Write more than 4096 bytes to test buffer flushing
    const large_entry = "X" ** 1000;
    for (0..5) |_| {
        try wal.writeEntry(large_entry);
    }

    var entries = try wal.readEntries();
    defer entries.deinit();

    try testing.expectEqual(@as(usize, 5), entries.items.len);
    for (entries.items) |entry| {
        try testing.expectEqualStrings(large_entry, entry);
    }
}

test "WAL concurrent writes" {
    const test_filename = "test_wal_concurrent.log";
    defer fs.cwd().deleteFile(test_filename) catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var wal = try WAL.init(allocator, test_filename);
    defer wal.deinit();

    const ThreadContext = struct {
        wal: *WAL,
        id: usize,
    };

    const thread_count = 10;
    var threads: [thread_count]std.Thread = undefined;

    const writerThread = struct {
        fn run(ctx: ThreadContext) !void {
            const entry = try std.fmt.allocPrint(ctx.wal.allocator, "Entry from thread {}", .{ctx.id});
            defer ctx.wal.allocator.free(entry);
            try ctx.wal.writeEntry(entry);
        }
    };

    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, writerThread.run, .{
            ThreadContext{ .wal = &wal, .id = i },
        });
    }

    for (threads) |thread| {
        thread.join();
    }

    try wal.flush();

    var entries = try wal.readEntries();
    defer entries.deinit();

    try testing.expectEqual(@as(usize, thread_count), entries.items.len);
}
