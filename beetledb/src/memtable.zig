//
// Although this is a memtable, this implements
// both, b+tree and lsm tree (with sst table)
//
const std = @import("std");

const fs = std.fs;
const testing = std.testing;

const Allocator = std.mem.Allocator;

const PageType = enum(u8) {
    InteriorPage = 1,
    DataPage = 2, // Leaf pages
    IndexPage = 3,
};

export const FileHeader = struct {
    crc: u32,
    offset: u32,
    prev: u32,
    next: u32,
    t: u8,
    // lsn: u32, // log sequence number
    space_id: u32,
};

const NodeType = enum(u8) {
    InternalNode = 1,
    LeafNode = 2,
    Deleted = 3,
};

const DBErrors = error{
    KeyNotFound,
    OutofSpace,
    DuplicateKey,
    InvalidNodeType,
};

pub const Node = struct {
    node_t: NodeType,
    n_keys: u32, // this is max_keys for now, will need to see if we need a keys counter.
    keys: []u64,
    values: ?[]std.ArrayList(u8), // []std.ArrayListAligned

    children: ?[]Node,
    parent: ?*Node,
    right: ?*Node,
    // we will see about this
    allocator: *std.mem.Allocator,

    pub fn init(allocator: *std.mem.Allocator, node_t: NodeType, max_keys: u32, parent: ?*Node) !*Node {
        const node = try allocator.create(Node);
        const is_leaf = if (node_t == NodeType.LeafNode) true else false;

        node.* = Node{
            .node_t = node_t,
            .n_keys = 0,
            .keys = try allocator.alloc([]u64, max_keys),
            .values = if (is_leaf) try allocator.alloc(std.ArrayList(u8), max_keys) else null,
            .children = if (!is_leaf) try allocator.alloc(?*Node, max_keys + 1) else null,
            .parent = parent,
            .right = null,
            .allocator = allocator,
        };

        if (!is_leaf) {
            for (node.children.?) |*child| {
                child.* = null;
            }
        }

        return node;
    }

    pub fn insert(self: *Node, key: u64, value: std.ArrayList(u8)) !void {
        // pip: possible_insert_point
        const pip = self.binary_search(key);

        if (self.keys.len >= self.n_keys) {
            std.debug.print("time to split?\n", .{});
            return DBErrors.OutofSpace;
        }

        if (pip < self.n_keys and self.keys[pip] == key) {
            return DBErrors.DuplicateKey;
        }

        var tmp: usize = self.n_keys;
        while (tmp > pip) : (tmp -= 1) {
            self.keys[tmp] = self.keys[tmp - 1];
            // if its a leaf node, value goes to values
            // if its internal, ideally value should point
            // to a leaf node

            if (self.node_t == NodeType.LeafNode) {
                self.values.?[tmp] = self.values.?[tmp - 1];
            } else if (self.node_t == NodeType.InternalNode) {
                self.children.?[tmp + 1] = self.children.?[tmp];
            } else {
                return DBErrors.InvalidNodeType;
            }
        }

        self.keys[pip] = key;

        if (self.node_t == NodeType.LeafNode) {
            self.values.?[pip] = value;
        } else if (self.node_t == NodeType.LeafNode) {
            self.children.?[pip + 1] = self.children.?[pip];
            self.children.?[pip] = null;
        } else {
            return DBErrors.InvalidNodeType;
        }
    }

    // This is more of bisect left, will need to see if handling with
    // == makes a difference
    pub fn binary_search(self: *Node, target_key: u64) usize {
        var lo: usize = 0;
        var hi: usize = self.n_keys;

        while (lo < hi) {
            const mid = lo + ((hi - lo) >> 1);

            if (target_key <= self.keys[mid]) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }

        return lo;
    }

    pub fn deinit(self: *Node) !void {
        self.allocator.free(self.keys);

        if (self.values) |*values| {
            for (values) |*value| {
                self.allocator.free(value);
            }

            self.allocator.free(values);
        }

        if (self.children) |children| {
            for (children) |child| {
                if (child == null) continue;
                child.deinit();
            }

            self.allocator.free(children);
        }

        if (self.right != null) {
            self.allocator.free(self.right);
        }

        self.allocator.destroy(self);
    }
};

const BLittle = std.builtin.Endian.little;

pub const Record = struct {
    id: u64,
    name: []const u8,
    email: []const u8,

    fn serialize(self: *Record, allocator: *std.mem.Allocator) ![]u8 {
        const buf_len = @sizeOf(u64) + self.name.len + self.email.len;
        const buf = try allocator.alloc(u8, buf_len);
        errdefer allocator.free(buf);

        var stream = std.io.fixedBufferStream(buf);
        var writer = stream.writer();

        try writer.writeInt(u64, self.id, BLittle);
        try writer.writeAll(self.name);
        try writer.writeAll(self.email);

        return buf;
    }
};

pub const BTree = struct {
    root: *Node,
    order: u32,
    allocator: *std.mem.Allocator,

    pub fn init(allocator: *std.mem.Allocator, order: u32) *BTree {
        const btree = try allocator.create(BTree);

        btree.* = BTree{
            .allocator = allocator,
            .order = order,
            .root = Node.init(allocator, NodeType.InternalNode, order),
        };

        return btree;
    }

    pub fn insert(self: *BTree, record: *Record) !void {
        // search where to insert
        // once found, check the number of keys from the parent
        // if its 1/2 full, split it.
        _ = self;
        _ = record;
    }

    pub fn search(self: *BTree, key: u64) !*Node {
        var cur: *Node = self.root;

        while (cur.node_t != NodeType.LeafNode) {
            const i: usize = try cur.binary_search(key);

            if (i < cur.keys and key == cur.keys[i]) {
                return cur.keys[i];
            }
        }

        return error.KeyNotFound;
    }
};
