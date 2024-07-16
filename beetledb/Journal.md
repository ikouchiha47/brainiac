## Journal

```shell
$> zig init
$> sqlite3 test.sqlite3
```

```sql
CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username VARCHAR(32),
        email VARCHAR(255)
    );

```

```shell
$> python3 populate.py
$> stat test.sqlite3

 File: test.sqlite3
 Size: 3534848         Blocks: 6904       IO Block: 4096   regular file
Device: 0,41    Inode: 4762433     Links: 1
Access: (0644/-rw-r--r--)  Uid: ( 1000/darksied)   Gid: ( 1000/darksied)
```

```shell
$> echo "3534848/4096" | bc -l
# 863.000
```

Using [Sqlite DB Format](https://www.sqlite.org/fileformat.html) and opening
the database file in hex editor/viewer or your choice

```shell
HEXEDITOR=xvi #or hexedit
$HEXEDITOR test.sqlite3
```

The thing is 0 indexed, so at position 16 and 17, we see hex 1000 and,
from 28-31 number of pages used = 0000035F = 863 pages

## Start

After writing the parser, and help from a friend, I started to write the data storage part incrementally.
Instead of a btree, implement basic saving to bytes to file.

Serialize and Deserialize it.

The serialization and save to file works. Test with:

```shell
cat test.db | xxd -b
```
