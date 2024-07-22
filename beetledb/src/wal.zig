const std = @import("std");
const Crc32Ieee = std.hash.Crc32;

const testing = std.testing;

// https://github.com/facebook/rocksdb/wiki/Write-Ahead-Log-File-Format
// Using this to structure for WAL logs

// const N_CRC: u8 = 4;
// const N_SIZE: u8 = 2;
// const N_TYPE: u8 = 1;
// const N_LOG_NUM: u8 = 4;

// This is the sum of the above four

const RecordType = enum(u8) {
    FULL = 1,
    FIRST = 2,
    MIDDLE = 3,
    LAST = 4,
    PACKED = 5,
    COMPRESSED = 6,
    RECYCLED = 7,
};

const LittleEndian = std.builtin.Endian.little;

pub fn CrcIt(t: RecordType, str: []const u8) u32 {
    var h = std.hash.Crc32.init();
    const rt: u8 = @intCast(@intFromEnum(t));

    h.update(&[_]u8{rt});
    h.update(str);

    return h.final();
}

const N_HEADER_SIZE: u8 = 4 + 2 + 1;
const N_REUSE_HEADER_SIZE: u8 = 4 + 2 + 1 + 4;

const Record = struct {
    crc: u32,
    size: u16,
    log_number: u16, // skipping it for now
    t: RecordType,
    payload: []const u8,

    pub fn serialize(self: *Record, allocator: *std.mem.Allocator) ![]u8 {
        const header_size = if (@intFromEnum(self.t) < 6) N_HEADER_SIZE else N_REUSE_HEADER_SIZE;

        const buf_len = header_size + self.size;
        const buf = try allocator.alloc(u8, buf_len);
        errdefer allocator.free(buf);

        var stream = std.io.fixedBufferStream(buf);
        var writer = stream.writer();

        try writer.writeInt(u32, self.crc, LittleEndian);
        try writer.writeInt(u16, self.size, LittleEndian);
        try writer.writeInt(u8, @intFromEnum(self.t), LittleEndian);
        // try writer.writeInt(u16, self.log_number, LittleEndian);
        try writer.writeAll(self.payload);

        return buf;
    }
};

const BLOCK_SIZE: usize = 32 * 1024; //32KB

// block := record* trailer?
// record :=
//   checksum: uint32	// crc32c of type and data[]
//   length: uint16
//   type: uint8		// One of FULL, FIRST, MIDDLE, LAST
//   data: uint8[length]
//
// if exactly seven bytes are left in the current block, and a new non-zero length record is added,
// the writer must emit a FIRST record (which contains zero bytes of user data) to
// fill up the trailing seven bytes of the block
// and then emit all of the user data in subsequent blocks.
//
// https://github.com/facebook/rocksdb/tree/master/db/log_writer.h

const WAL = struct {
    file: std.fs.File,
    allocator: *std.mem.Allocator,
    log_number: u16,
    mutex: std.Thread.Mutex,
    offset: u64, // handle the 32K block offset

    pub fn init(allocator: *std.mem.Allocator, filename: []const u8, start_log_number: u16) !WAL {
        const file = try std.fs.cwd().createFile(filename, .{ .read = true, .truncate = false });

        return WAL{
            .file = file,
            .allocator = allocator,
            .log_number = start_log_number,
            .mutex = std.Thread.Mutex{},
            .offset = 0,
        };
    }

    pub fn deinit(self: *WAL) void {
        self.file.close();
    }

    pub fn write(self: *WAL, entry: []const u8) !void {
        var writer = self.file.writer();
        var remaining = entry;
        var begin = true;

        // std.debug.print("=======\n", .{});
        // std.debug.print("starting entry: {any}, offset {any}\n", .{ entry.len, self.offset });

        while (remaining.len > 0) {
            const space_in_block = BLOCK_SIZE - self.offset;
            // std.debug.print("space remaining in block {any}. is overflow {any}\n", .{ space_in_block, space_in_block <= N_HEADER_SIZE });

            if (space_in_block <= N_HEADER_SIZE) {
                // zero out the remaining space
                const zeros = try self.allocator.alloc(u8, space_in_block);
                errdefer self.allocator.free(zeros);

                @memset(zeros, 0);

                // std.debug.print("zeroing rest {any} and reseting offset\n", .{remaining.len});
                try writer.writeAll(zeros);

                self.offset = 0;
            }

            // Get the available space, and
            // Get the total amount to data to be written
            // Determine the record type based on
            // Create the record and write the fragment
            // Reset remaining for rest of the data
            const avail = BLOCK_SIZE - N_HEADER_SIZE - self.offset;
            const data_capacity = @min(remaining.len, avail);

            // std.debug.print("data capacity {any} available {any}\n", .{ data_capacity, avail });
            var record_type: RecordType = RecordType.MIDDLE;

            if (begin and data_capacity == remaining.len) {
                record_type = RecordType.FULL;
            } else if (begin and data_capacity < remaining.len) {
                record_type = RecordType.FIRST;
            } else if (data_capacity == remaining.len) {
                record_type = RecordType.LAST;
            } else {
                record_type = RecordType.MIDDLE;
            }

            const data = remaining[0..data_capacity];
            var r = Record{
                .crc = CrcIt(record_type, data), // could reduce the copying here
                .size = @intCast(data_capacity),
                .log_number = self.log_number,
                .t = record_type,
                .payload = data,
            };
            const serialized = try r.serialize(self.allocator);
            errdefer self.allocator.free(serialized);

            try writer.writeAll(serialized);
            self.offset += serialized.len;

            remaining = remaining[data_capacity..];
            begin = false;
        }

        try self.flush();
    }

    pub fn flush(self: *WAL) !void {
        try self.file.sync();
    }
};

test "WAL basic operations" {
    const test_filename = "test_wal.log";
    // defer std.fs.cwd().deleteFile(test_filename) catch {};

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    var wal = try WAL.init(&allocator, test_filename, 1);
    defer wal.deinit();

    const record_a = try allocator.alloc(u8, 1000);
    defer allocator.free(record_a);
    @memset(record_a, 'A');

    const record_b = try allocator.alloc(u8, 97270);
    defer allocator.free(record_b);
    @memset(record_b, 'B');

    // Write records
    try wal.write(record_a);
    try wal.write(record_b);
}
