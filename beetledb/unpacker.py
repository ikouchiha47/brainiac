import struct


def read_data(filename):
    with open(filename, "rb") as file:
        # Read the first 2 bytes (u16) for the number
        num_bytes = file.read(2)
        num = struct.unpack("<H", num_bytes)[0]

        # Read the next 2 bytes (u16) for the string length
        str_len_bytes = file.read(2)
        str_len = struct.unpack("<H", str_len_bytes)[0]

        # Read the string
        str_bytes = file.read(str_len)
        str_value = str_bytes.decode("utf-8")

    return num, str_value


# Example usage
filename = "test.db"
number, string = read_data(filename)
print(f"Number: {number}")
print(f"String: {string}")
