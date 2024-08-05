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
# The layout is split into two parts
# (DataType::Node, Index, Depth, Node1), (DataType::Node, Depth, Index, Node2)...
# (DataType::Lane, BaseNodeIndex, FwdPointerIndices)
#
# The layout is missing a checksum generation, and versioning.
# but we will comeback to that later.
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

    # step 1, save pull list
    # step 2, save differences
    # step 3, split into page size chunks

    # layout
    # data_type = enum {data, lane}

    # magic_byte + 0 * (page_size - len(magic_bytes))
    # data_type_data|index|data_length|levels_count|node_encoded (deal with page numbers later)
    #
    # data_type_lane|level|count|node_index|fwd_index_0|fwd_node_index0|fwd_index_1|fwd_node_index1
    # either that or,
    # data_type_lane|level|count|node_index|fwd_index0|-1|fwd_node_index_1...
    # will go with 2nd one for now
    # \xEE\x0F
    def marshal_to_page(self, skplist: SkipList):
        result = bytearray()
        print("skiplist info", skplist.max_level, skplist.level)

        result.extend(MAGIC_BYTE)
        result.extend(b"\x00\x00\x00")  # estlye, for metadata and flags

        # maybe pad with PAGE_SIZE - len(result)

        nodes: Set[SkipNode] = set()
        queue: List[SkipNode] = [skplist.head]

        while len(queue) > 0:
            n = queue.pop(0)
            nodes.add(n)
            queue.extend([fwd for fwd in n.forwards if fwd and fwd not in nodes])

        for n in nodes:
            print("written", n.value, n.name, len(n.forwards))

        for index, node in enumerate(nodes):
            result.extend(TYPE_DATA)
            result.extend(struct.pack("<I", index))
            node_bytes = node.to_bytes()

            print("nodes info", len(node.forwards))
            # print("lll", len(node_bytes), node_bytes)
            result.extend(struct.pack("<I", len(node_bytes)))
            result.extend(node_bytes)

        # considering adjusting by page size
        lnodes, node_count = list(nodes), len(nodes)

        print("len forwards", [len(node.forwards) for node in lnodes])

        for node in nodes:
            result.extend(TYPE_LANE)
            result.extend(struct.pack("<I", lnodes.index(node)))

            for fwd in node.forwards:
                idx = 0xFFFF
                if fwd:
                    idx = lnodes.index(fwd)
                result.extend(struct.pack("<I", idx))

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

        result.extend(EOF)
        return result

    def marshal_from_page(self, data: bytes):
        offset = 4
        mem = memoryview(data)

        if mem[:offset].tobytes() != MAGIC_BYTE:
            raise Exception("incompatible_file")

        # xx = mem[offset : offset + 3]
        # print("xx", xx.tobytes())
        offset += 3
        nodes: Dict[int, SkipNode] = {}
        lanes = []

        # for a pretty long table this
        # is going to takeup a lot of time
        # loading by pages or check how sqlite/mysql/levelDB does it

        # max_level is fixed, we might as well store it
        skplist = SkipList(max_level=5, probab=0.25)
        # prev_offset = 0

        while offset < len(mem):
            # print("endbyte", offset, mem[offset : offset + 2].tobytes())
            # if prev_offset == offset:
            #     break
            if mem[offset : offset + 2].tobytes() == EOF:
                break

            node_type = mem[offset : offset + len(TYPE_DATA)]
            offset += len(TYPE_DATA)
            # prev_offset = offset

            if node_type == TYPE_DATA:
                # print("parsing data")
                # print("yy", node_type.tobytes())

                index = struct.unpack_from("<I", mem, offset)[0]
                offset += 4
                node_bytes = struct.unpack_from("<I", mem, offset)[0]
                offset += 4

                node = SkipNode.from_bytes(mem[offset : offset + node_bytes])
                nodes[index] = node
                offset += node_bytes
                # print("index", index, "node", node.name, node.value)

            elif node_type == TYPE_LANE:
                base_node_idx = struct.unpack_from("<I", mem, offset)[0]
                offset += 4
                node = nodes[base_node_idx]

                level_nodes = []
                for i in range(node.level):
                    idx = struct.unpack_from("<I", mem, offset)[0]
                    offset += 4

                    level_nodes.append(nodes[idx] if idx != 0xFFFF else None)

                for level, fwd_node in enumerate(level_nodes):
                    node.forwards[level] = fwd_node

        print("node_count", len(nodes), nodes)
        # print("lanes_count", len(lanes), lanes)

        # we will use head as the one who n.name is head
        # need to modify the writer to keep the indexes in order
        # 0 for head, 1 for next, 2 for next, ... so on
        for n in nodes.values():
            print("reading", n.value, n.name, len(n.forwards))
        # print("head", nodes[0].value, len(nodes[0].forwards))
        # print("", nodes[0].value, len(nodes[0].forwards))
        # recreate the list

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
