from typing import List, Self
import random
import struct


class SkipNode:
    def __init__(self, name, value=None, max_level=16):
        self.name = name
        self.value = value
        self.level = max_level + 1
        self.forwards: List[Self | None] = [None] * (max_level + 1)

    def to_bytes(self):
        result = bytearray()
        name_encoded = self.name.encode("utf-8")
        value_encoded = 0xFFFF if self.value is None else self.value

        # I has a standard size of 4bytes , so maybe to_bytes of 4 is not needed
        result.extend(struct.pack("<I", len(self.name)))  # key length
        result.extend(name_encoded)  # key
        result.extend(struct.pack("<I", value_encoded))  # value
        result.extend(struct.pack("<I", self.level))  # level

        return result

    @classmethod
    def from_bytes(cls, b, offset=0):
        key_len = struct.unpack_from("<I", b, offset)[0]  # or <4b
        offset += 4
        key = b[offset : offset + key_len].tobytes().decode("utf-8")
        offset += key_len
        value = struct.unpack_from("<I", b, offset)[0]
        offset += 4
        lvl = struct.unpack_from("<I", b, offset)[0]

        return SkipNode(
            name=key, value=value if value != 0xFFFF else None, max_level=lvl - 1
        )


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
        # print("level", new_lvl, "value", value, len(updates))

        # check if lvl > self.max_levels
        # then track new lanes to create for head
        if new_lvl > self.level:
            for i in range(self.level + 1, new_lvl + 1, 1):
                updates[i] = self.head
            self.level = new_lvl

        # print("new level", self.level, len(updates))

        node = SkipNode(key, value=value, max_level=new_lvl)
        # add the nodes at all levels, starting from 0
        # add the new nodes to the head node as well
        for lvl in range(new_lvl + 1):
            replacing = updates[lvl]
            if replacing is None:
                print("warning: no entry found in updates")
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

        for level in range(self.level, -1, -1):
            curr = self.head
            level_repr = []
            while curr:
                level_repr.append(f"{curr.name}({curr.value})")
                curr = curr.forwards[level]
            result[f"Level {level}"] = level_repr

        print(json.dumps(result))

    def first(self):
        pass


if __name__ == "__main__":
    skipnode = SkipNode(name="a", value=10)
    data = skipnode.to_bytes()
    print(data)
    SkipNode.from_bytes(memoryview(data))
    # skplist = SkipList(max_level=5, probab=0.5)
    # skplist.insert("a", 10).insert("b", 20).insert("c", 15).insert("d", 6)
    # skplist.print_list()
    #
    # nodes: Set[SkipNode] = set()
    # queue: List[SkipNode] = [skplist.head]
    #
    # while len(queue) > 0:
    #     n = queue.pop(0)
    #     nodes.add(n)
    #     # for fwd in n.forwards:
    #     # if fwd:
    #
    #     queue.extend([fwd for fwd in n.forwards if fwd])
    #
    # print(skplist.level, len(nodes))
    # print(skplist.search(15), skplist.search(40))
