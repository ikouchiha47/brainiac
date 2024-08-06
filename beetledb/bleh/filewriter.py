from collections import defaultdict
import struct
from typing import Dict, List, Set
from skiplist import SkipList, SkipNode

PAGE_SIZE = 4096

# to validate the start of the skiplist segment
# so that we don't start parsing anything

MAGIC_BYTE = b"\xde\xad\xbe\xef"

TYPE_NODE = b"\xbe"
TYPE_LANE = b"\xef"

EOF = b"\xee\x0f"

# visualizing the skiplist
# mthe usual image is a vertical stack with pointers
# to the next level
# but I think, if you turn the image 90deg making the
# stack appear horizontal, it starts to look like a tree
# the forward pointers are the edges (going up or down)
#
# +++++++++++++++++++++++++++++++++
# | Node1 (Value, Depth)          |  # <- head
# +++++++++++++++++++++++++++++++++
# |FwdPointer2| <nil> |FwdPointer3|
# +++++++++++++++++++++++++++++++++
#    /                     \
# ++++++++++++++         ++++++++++++++
# | Node2      |         | Node3      |
# ++++++++++++++         ++++++++++++++
# |Fwd Pointers|         |Fwd Pointers|
# ++++++++++++++         ++++++++++++++
#
# at the core, it has a bunch of nodes at specific indexes on each level
# we could store it like b+trees are stored
# for the time being we will do our own custom format, which kindof looks
# like what leveldb's block format looks like, yet utilizing the data type
# to indicate whether its a Node, or an Index on the Level
#
#
# The layout is split into three parts
# Metadata:
# Some magic number followed by some metadata
# rn the metadata includes the last highest level
#
# For each Node:
# (DataType::Node, Index, NodeDataLength, Node(KeyLength, Key, Value, Depth)), (DataType::Node, Index, NodeDataLength, Node2)...
# For Each Level
# (DataType::Lane, Level, LengthOfNodesAtLevel, NodeIndices)
#
# The layout is missing a checksum generation, and versioning.
# but we will comeback to that later.
#
# The other thing to consider is how to handle incremental updates
# if we store the present level in file
#
# There are a couple of ways I can think about:
# - Peridodically use a new base line file. Basically re-saving the file
# - Segment the file. Each file, can have its own level and data, and the storage engine can load it accordingly
# - Any other data format, which makes use of the level for each node. Need to think on that
#
# We can put the Depth/Level inside the node data, because levels
# of an already inserted node, doesn't change over time.
#
# Apart from this, we add a magic byte to the start of the file segment
# indicating that this file is parseable by this code
#
# Construction:
# Using BFS to get the list of unique nodes
# This helps to easily create using integer as Index
#
# Deconstruction:
#
# Parse the nodes data (DataType::Node), to create the list of nodes with their indices
#   (index, SkipNode(key=key, value=value,levels=level))
# Parse the lanes data (DataType::Lane).
#   Parse: BaseNodeIndex
#     Get the Depth from the above, which will
#     produce the number of 4bytes to parse which are the FwdIndices
#     The FwdIndices are in the order of insertion, so another index is not necessary here
#   For each node, update the list of FwdPointers (nodes[index])


class FileWriter:
    def __init__(self, filename) -> None:
        self.filename = filename

    def marshal(self, skplist: SkipList):
        result = bytearray()
        # skplist.print_list()

        result.extend(MAGIC_BYTE)
        result.extend(struct.pack("<I", skplist.level))
        result.extend(b"\x00\x00\x00")  # estlye, for metadata and flags

        # maybe pad with PAGE_SIZE - len(result)

        nodes: Dict[SkipNode, int] = {}
        queue: List[SkipNode] = [skplist.head]
        leveled_nodes: Dict[int, List[SkipNode]] = {}

        # using the index as level for bfs
        index = 0
        while queue:
            n = queue.pop(0)
            if n not in nodes:
                nodes[n] = index
                index += 1
                queue.extend([fwd for fwd in n.forwards if fwd and fwd not in nodes])

        for node, level in nodes.items():
            result.extend(TYPE_NODE)
            result.extend(struct.pack("<I", level))

            node_bytes = node.to_bytes()
            result.extend(struct.pack("<I", len(node_bytes)))
            result.extend(node_bytes)

        # get nodes at each level
        # why this works? Because the forward entries won't have a
        # None in between.
        for level in range(skplist.level, -1, -1):
            curr = skplist.head
            level_repr = []

            while curr and len(curr.forwards) > level:
                level_repr.append(curr)
                curr = curr.forwards[level]
            leveled_nodes[level] = level_repr

        for level, _nodes in leveled_nodes.items():
            result.extend(TYPE_LANE)
            result.extend(struct.pack("<II", level, len(_nodes)))

            for node in _nodes:
                idx = nodes[node] if node else 0xFFFF
                result.extend(struct.pack("<I", idx))
                # print("inserting", "DataType::Lane", level, len(_nodes), idx)

        result.extend(EOF)
        return result

    def unmarshal(self, data: bytes):
        offset = 4
        mem = memoryview(data)

        if mem[:offset].tobytes() != MAGIC_BYTE:
            raise Exception("incompatible_file")

        skiplist_level = struct.unpack_from("<I", mem, offset)[0]
        offset += 4

        offset += 3
        nodes: Dict[int, SkipNode] = {}

        # for a pretty long table this
        # is going to takeup a lot of time
        # loading by pages or check how sqlite/mysql/levelDB does it

        # max_level is fixed, we might as well store it
        skplist = SkipList(max_level=5, probab=0.25)
        skplist.level = skiplist_level

        # parsing node TYPE_DATA
        while offset < len(mem):
            if mem[offset : offset + 2].tobytes() == EOF:
                break

            node_type = mem[offset : offset + len(TYPE_NODE)]
            if node_type != TYPE_NODE:
                print("end of parsing node")
                break

            offset += len(TYPE_NODE)

            index = struct.unpack_from("<I", mem, offset)[0]
            offset += 4
            node_bytes = struct.unpack_from("<I", mem, offset)[0]
            offset += 4

            node = SkipNode.from_bytes(mem[offset : offset + node_bytes])
            nodes[index] = node

            if node.name == "head":
                skplist.head = node

            offset += node_bytes

        # parsing levels: TYPE_LANE
        while offset < len(mem):
            if mem[offset : offset + 2].tobytes() == EOF:
                break

            if mem[offset : offset + len(TYPE_LANE)] != TYPE_LANE:
                break

            offset += len(TYPE_LANE)
            level, n_forwards = struct.unpack_from("<II", mem, offset)
            offset += 8

            # print("read lane metadata", "level", level, "lnodes", n_forwards)
            # each forward idx is 4 byte(I)

            curr = skplist.head
            for _ in range(n_forwards):
                nidx = struct.unpack_from("<I", mem, offset)[0]
                offset += 4

                if nidx != 0xFFFF:
                    curr.forwards[level] = nodes[nidx]
                    curr = nodes[nidx]

        assert mem[offset : offset + 2] == EOF, "failed unexpectedly"
        skplist.print_list()
        return skplist

    def write_to_file(self, list):
        result = self.marshal(list)
        with open(self.filename, "wb") as f:
            print("written", len(result))
            f.write(bytes(result))

    def read_from_file(self):
        with open(self.filename, "rb") as f:
            data = f.read()

        print("reading", len(data))
        # print(data)
        # self._print_hex_list(data)
        self.unmarshal(data)

    def _print_hex_list(self, data):
        byte_list = list(data)

        # Convert each byte to its hexadecimal representation
        hex_list = [f"{byte:02x}" for byte in byte_list]

        # Print the resulting list
        print([(i, item) for i, item in enumerate(hex_list)])


if __name__ == "__main__":
    skplist = SkipList(max_level=5, probab=0.5)
    skplist.insert("a", 10).insert("b", 20).insert("c", 15).insert("d", 6)
    # skplist.print_list()

    nodes: Set[SkipNode] = set()
    queue: List[SkipNode] = [skplist.head]

    while len(queue) > 0:
        n = queue.pop(0)
        nodes.add(n)
        for fwd in n.forwards:
            if fwd:
                nodes.add(fwd)

    # print(skplist.level, len(nodes))

    f = FileWriter("skiplist.dat")
    f.write_to_file(skplist)

    f.read_from_file()
