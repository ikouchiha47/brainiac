const std = @import("std");
const Allocator = std.mem.Allocator;

const Order = 4;

const NodeType = enum(u8) {
    Internal,
    Leaf,
};

const Node = struct {
    type: NodeType,
    num_keys: u16,
    keys: [Order - 1]i64,
    children: [Order]u64, // Disk offsets for child nodes
    next: u64, // Next leaf node (for leaf nodes only)
};

const NodeSize = @sizeOf(Node);

pub const BPlusTree = struct {
    root: u64, // Disk offset of root node
    allocator: *Allocator,
    file: std.fs.File,

    fn readNode(self: *BPlusTree, offset: u64) !Node {
        var node: Node = undefined;
        _ = try self.file.seekTo(offset);
        _ = try self.file.readAll(std.mem.asBytes(&node));
        return node;
    }

    fn writeNode(self: *BPlusTree, offset: u64, node: *const Node) !void {
        _ = try self.file.seekTo(offset);
        _ = try self.file.writeAll(std.mem.asBytes(node));
    }

    fn allocateNode(self: *BPlusTree) !u64 {
        const offset = try self.file.getEndPos();
        try self.file.seekTo(offset);
        var node = Node{
            .type = .Leaf,
            .num_keys = 0,
            .keys = undefined,
            .children = undefined,
            .next = 0,
        };
        try self.writeNode(offset, &node);
        return offset;
    }

    fn insert(self: *BPlusTree, key: i64, value: u64) !void {
        _ = self;
        _ = key;
        _ = value;
    }

    fn search(self: *BPlusTree, key: i64) !?u64 {
        var node = try self.readNode(self.root);
        while (node.type == .Internal) {
            var i: usize = 0;
            while (i < node.num_keys and key >= node.keys[i]) : (i += 1) {}
            node = try self.readNode(node.children[i]);
        }

        for (node.keys[0..node.num_keys], node.children[0..node.num_keys]) |k, v| {
            if (k == key) return v;
        }

        return null;
    }

    pub fn deinit(self: *BPlusTree) void {
        self.file.close();
    }
};
