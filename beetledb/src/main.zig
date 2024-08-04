const std = @import("std");
const Writer = @import("writetest.zig").Writer;
const Data = @import("writetest.zig").Data;

pub fn main() !void {
    var allocator = std.heap.page_allocator;

    // Example usage:
    var writer = try Writer.open(&allocator, "test.db");

    defer {
        // Ensure the writer is closed, even if an error occurs
        writer.close();
    }

    var exampleData = Data{
        .num = 42,
        .str = "Hello, Zig!",
    };

    try writer.write(&exampleData);
}
