import struct
from typing import List, Set
from skiplist import SkipList, SkipNode

PAGE_SIZE = 4096

# to validate the start of the skiplist segment
# so that we don't start parsing anything

MAGIC_BYTE = b"\xde\xad\xbe\xef"

TYPE_DATA = b"\xbe"
TYPE_LANE = b"\xef"

EOF = b"\xee\x0f"


class FileWriter:
    def __init__(self, filename) -> None:
        self.filename = filename

    # step 1, save pull list
    # step 2, save differences
    # step 3, split into page size chunks

    # layout
    # data_type = enum {data, lane}

    # magic_byte + 0 * (page_size - len(magic_bytes))
    # data_type_data|index|data_length|node_encoded (deal with page numbers later)
    # data_type_data|index|data_length|node_encoded
    # ...
    # data_type_lane|level|count|index_0|node_index0|index_1|node_index1
    # either that or,
    # data_type_lane|level|count|node_index0|-1|node_index1...
    # \xEE\xOF
    def marshal_to_page(self, skplist: SkipList):
        result = bytearray()

        result.extend(MAGIC_BYTE)
        result.extend(b"\x00\x00\x00")  # estlye, for metadata and flags

        # maybe pad with PAGE_SIZE - len(result)

        nodes: Set[SkipNode] = set()
        queue: List[SkipNode] = [skplist.head]

        while len(queue) > 0:
            n = queue.pop(0)
            nodes.add(n)
            queue.extend([fwd for fwd in n.forwards if fwd])

        for index, node in enumerate(nodes):
            result.extend(TYPE_DATA)
            result.extend(struct.pack("<I", index))
            node_bytes = node.to_bytes()
            # print("lll", len(node_bytes), node_bytes)
            result.extend(struct.pack("<I", len(node_bytes)))
            result.extend(node_bytes)

        # considering adjusting by page size
        lnodes, node_count = list(nodes), len(nodes)

        for l in range(skplist.level, -1, -1):
            result.extend(TYPE_LANE)
            result.extend(struct.pack("<I", node_count))

            for node in nodes:
                idx = 0xFFFFFFFF
                # print("len:", len(node.forwards), l)
                if len(node.forwards) > l and node.forwards[l]:
                    idx = lnodes.index(node.forwards[l])
                result.extend(struct.pack("<I", idx))

        result.extend(EOF)
        return result

    def marshal_from_page(self, data: bytes):
        offset = 4
        mem = memoryview(data)

        # print("mem", mem.tobytes())

        if mem[:offset].tobytes() != MAGIC_BYTE:
            raise Exception("incompatible_file")

        # xx = mem[offset : offset + 3]
        # print("xx", xx.tobytes())
        offset += 3

        # read 4 nodes manually
        node_type = mem[offset : offset + len(TYPE_DATA)]

        # print("yy", node_type.tobytes())
        offset += len(TYPE_DATA)

        # print(mem[offset:].tobytes())

        index = struct.unpack_from("<I", mem, offset)[0]
        offset += 4
        node_bytes = struct.unpack_from("<I", mem, offset)[0]
        offset += 4
        # print("rr", mem[offset : offset + 4].tobytes())

        node = SkipNode.from_bytes(mem[offset : offset + node_bytes])
        print("index", 1, "node", node.name, node.value)
        # print(node_type.to_bytes(), index, node_bytes)

    def write_to_file(self, list):
        result = self.marshal_to_page(list)
        with open(self.filename, "wb") as f:
            print("written", len(result))
            f.write(bytes(result))

    def read_from_file(self):
        with open(self.filename, "rb") as f:
            data = f.read()

        print("reading", len(data))
        self.marshal_from_page(data)


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
    # f.write_to_file(skplist)

    f.read_from_file()
