from typing import List, Self
import random
import struct


class SkipNode:
    def __init__(self, name, value=None, max_level=16):
        self.name = name
        self.value = value
        self.forwards: List[Self | None] = [None] * (max_level + 1)

    # each frame looks like
    # key_length 4bytes
    # key variable length (we could cap this)
    # value
    def to_bytes(self):
        result = bytearray()
        name_encoded = self.name.encode("utf-8")
        # TODO: encode this shit
        value_encoded = -1 if self.value is None else self.value
        # value_encoded = value_encoded.to_bytes(4, byteorder="little", signed=True)
        # return (
        #     struct.pack("<I", len(self.name))
        #     + name_encoded
        #     + struct.pack("<d", self.value if self.value is not None else -1)
        # )
        # I has a standard size of 4bytes , so maybe to_bytes of 4 is not needed
        result.extend(struct.pack("<I", len(self.name)))
        result.extend(name_encoded)
        result.extend(struct.pack("<I", value_encoded))
        return bytes(result)

    @classmethod
    def from_bytes(cls, byts):
        b = memoryview(byts)
        offset = 0
        key_len = struct.unpack_from("<I", b, offset)[0]  # or <4b
        offset += 4
        key = b[offset : offset + key_len].tobytes().decode("utf-8")
        offset += key_len
        value = struct.unpack_from("<I", b, offset)[0]

        print(key, value)
        return SkipNode(name=key, value=value)


class SkipList:
    def __init__(self, max_level, probab) -> None:
        self.max_level = max_level
        self.probab = probab
        self.head = SkipNode("head", max_level=max_level)
        self.level = 0
        self.size = 0

    def _random_level(self):
        if self.size % 2 == 0:
            level = random.randint(0, self.max_level // 2)
        else:
            level = random.randint(self.max_level // 2, self.max_level)
        return level
        # level = 0
        # while random.random() < self.probab and level < self.max_level:
        #     level += 1
        # return level

    def insert(self, key, value):
        # starting from max level
        # find the position for update
        curr = self.head
        if curr is None:
            raise Exception("Empty")

        updates: List[SkipNode | None] = [None] * (self.max_level + 1)

        # iterate the head to find the levels
        # to insert the node at
        for i in range(self.level, -1, -1):
            while curr and curr.forwards[i] and curr.forwards[i].value < value:
                curr = curr.forwards[i]

            updates[i] = curr

        new_lvl = self._random_level()
        # print("level", new_lvl, "value", value)

        # check if lvl > self.max_levels
        # then track new lanes to create for head
        if new_lvl > self.level:
            for i in range(self.level + 1, new_lvl + 1, 1):
                updates[i] = self.head
            self.level = new_lvl

        node = SkipNode(key, value=value, max_level=new_lvl)
        # add the nodes at all levels, starting from 0
        # add the new nodes to the head node as well
        for lvl in range(new_lvl + 1):
            replacing = updates[lvl]
            if replacing is None:
                continue
            node.forwards[lvl] = replacing.forwards[lvl]
            replacing.forwards[lvl] = node

        self.size += 1

        return self

    def search(self, value):
        # check at each level starting from the maximum
        curr = self.head
        for i in range(self.level, -1, -1):
            while curr and curr.forwards[i] and curr.forwards[i].value < value:
                curr = curr.forwards[i]

        if curr is None:
            return False

        # precautionary
        curr = curr.forwards[0]
        return curr is not None and curr.value == value

    def remove(self, value):
        curr = self.head
        updates: List[SkipNode | None] = [None] * (self.max_level + 1)

        for i in range(self.level, -1, -1):
            while curr and curr.forwards[i] and curr.forwards[i].value < value:
                curr = curr.forwards[i]
            updates[i] = curr

        if curr is None or (curr and curr.forwards[0]) is None:
            return False

        curr = curr.forwards[0]
        if curr and curr.value != value:
            return False

        for i in range(self.max_level, -1, -1):
            replacement = updates[i]
            if not replacement:
                continue
            if replacement.forwards[i] != curr:
                raise Exception("node_mismatch")
            replacement.forwards[i] = curr.forwards[i]

        while self.level > 0 and self.head.forwards[self.max_level] is None:
            self.level -= 1
        self.size -= 1

    def print_list(self):
        from collections import defaultdict
        import json

        result = defaultdict(list)

        for i in range(self.level, -1, -1):
            curr = self.head
            # while curr and curr.forwards:
            # print("info", i, len(curr.forwards))
            while curr and curr.forwards[i]:
                value = curr.forwards[i].value
                result[curr.name].append(value)
                curr = curr.forwards[i]
            # curr = curr.forwards[i] if curr.forwards[i] else curr.forwards[0]

        print(json.dumps(result))

    def first(self):
        pass


if __name__ == "__main__":
    skipnode = SkipNode(name="a", value=10)
    data = skipnode.to_bytes()
    print(data)
    SkipNode.from_bytes(data)
    # skplist = SkipList(max_level=3, probab=0.5)
    # skplist.insert("a", 10).insert("b", 20).insert("c", 15).insert("d", 6)
    # skplist.print_list()
    # print(skplist.search(15), skplist.search(40))
