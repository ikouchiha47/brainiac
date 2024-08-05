from collections import defaultdict
import struct
from typing import Dict, List, Set
from skiplist import SkipList, SkipNode

PAGE_SIZE = 4096

# to validate the start of the skiplist segment
# so that we don't start parsing anything

MAGIC_BYTE = b"\xde\xad\xbe\xef"

TYPE_DATA = b"\xbe"
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

    def marshal_to_page(self, skplist: SkipList):
        result = bytearray()
        # print("skiplist info", skplist.max_level, skplist.level)
        skplist.print_list()

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
            result.extend(TYPE_DATA)
            result.extend(struct.pack("<I", level))
            node_bytes = node.to_bytes()
            result.extend(struct.pack("<I", len(node_bytes)))
            result.extend(node_bytes)
            # print(
            #     "written",
            #     f"DataType::Node|Index({level})|Depth({node.level})|Name({node.name})|Value({node.value})",
            # )

        # considering adjusting by page size
        # lnodes, node_count = list(nodes), len(nodes)
        # print("len forwards", [len(node.forwards) for node in lnodes])

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
            # result.extend(struct.pack("<I", len(_nodes)))

            # print("lane metadata", "level", level, "lnodes", len(_nodes))

            # bb = bytearray()

            for node in _nodes:
                idx = nodes[node] if node else 0xFFFF
                # bb.extend(struct.pack("<I", idx))
                result.extend(struct.pack("<I", idx))
                # print("inserting", "DataType::Lane", level, len(_nodes), idx)

            # print("bytearr", bb, len(bb), 4 * len(_nodes))

        result.extend(EOF)
        return result

    def marshal_from_page(self, data: bytes):
        offset = 4
        mem = memoryview(data)

        if mem[:offset].tobytes() != MAGIC_BYTE:
            raise Exception("incompatible_file")

        skiplist_level = struct.unpack_from("<I", mem, offset)[0]
        offset += 4

        # xx = mem[offset : offset + 3]
        # print("xx", xx.tobytes())
        offset += 3
        nodes: Dict[int, SkipNode] = {}

        # for a pretty long table this
        # is going to takeup a lot of time
        # loading by pages or check how sqlite/mysql/levelDB does it

        # max_level is fixed, we might as well store it
        skplist = SkipList(max_level=5, probab=0.25)
        skplist.level = skiplist_level
        # prev_offset = 0

        # parsing type node

        while offset < len(mem):
            # print("endbyte", offset, mem[offset : offset + 2].tobytes())
            # if prev_offset == offset:
            #     break
            if mem[offset : offset + 2].tobytes() == EOF:
                break

            node_type = mem[offset : offset + len(TYPE_DATA)]
            if node_type != TYPE_DATA:
                print("end of data parsing", node_type)
                break

            offset += len(TYPE_DATA)
            # prev_offset = offset

            index = struct.unpack_from("<I", mem, offset)[0]
            offset += 4
            node_bytes = struct.unpack_from("<I", mem, offset)[0]
            offset += 4

            node = SkipNode.from_bytes(mem[offset : offset + node_bytes])
            nodes[index] = node

            if node.name == "head":
                skplist.head = node
                # print("level of head", len(skplist.head.forwards))

            offset += node_bytes
            # print("index", index, "node", node.name, node.value)

            # elif node_type == TYPE_LANE:
            #     n_forwards = struct.unpack_from("<I", mem, offset)[0]
            #     offset += 4
            #
            #     while offset < offset + n_forwards:
            #         node_idx = struct.unpack_from("<I", mem, offset)[0]
            #         offset += 4
            #
            #         if node_idx != 0xFFFF:

        # assert mem[offset : offset + len(TYPE_LANE)] == TYPE_LANE, "expected lanes"
        # offset += len(TYPE_LANE)

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
            for i in range(n_forwards):
                nidx = struct.unpack_from("<I", mem, offset)[0]
                offset += 4

                if nidx != 0xFFFF:
                    curr.forwards[level] = nodes[nidx]
                    curr = nodes[nidx]

        skplist.print_list()
        return skplist

    def write_to_file(self, list):
        result = self.marshal_to_page(list)
        with open(self.filename, "wb") as f:
            print("written", len(result))
            f.write(bytes(result))

    def read_from_file(self):
        with open(self.filename, "rb") as f:
            data = f.read()

        print("reading", len(data))
        # print(data)
        # self._print_hex_list(data)
        self.marshal_from_page(data)

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


# for l in range(skplist.level + 1):
#     result.extend(TYPE_LANE)
#     result.extend(struct.pack("<I", l))
#     result.extend(struct.pack("<I", node_count))
#     # result.extend(struct.pack("<I", node_count + 1))
#
#     i = 0
#     for node in nodes:
#         result.extend(struct.pack("<I", lnodes.index(node)))
#
#         for fwd in node.forwards:
#             idx = 0xFFFF
#             if fwd:
#                 # idx = 0xFFFF
#                 # if len(node.forwards) > l and node.forwards[l]:
#                 idx = lnodes.index(fwd)
#             result.extend(struct.pack("<I", idx))
#
#         i += 1
#
#     print("nc", node_count, "level", l, "results added since", i)
