# Journal

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

## WAL log

The first step was to implement storing and retrieving byte data from file.
Writing from zig and reading from [python struct pack](https://docs.python.org/3/library/struct.html).

The learning here is:

- Data inherently has no meaning, and it depends on the observer.
- Struct/Class etc has no meaning outside the language.
  You only write bytes in a particular format and read in that format.

The initial code is present in `./src/writetest.zig` and `./unpacker.py`.

The next step was to write the `WAL`, in `./src/wal.zig`. The format is taken from [rocksdb](https://github.com/facebook/rocksdb/tree/master/db/log_writer.h).
The entrypoint is from `db_impl.h`, and the locking is done outside the Writer.

References:
- [search log_writer.h](https://github.com/search?q=repo%3Afacebook%2Frocksdb%20log_writer.h&type=code)

## Storage

Initial inspiration:
- [innodb internals](https://blog.jcole.us/innodb/)
- [sqlite internals](https://github.com/sqlite/sqlite/blob/master/src/btreeInt.h)
- [bitmap index](https://dev.mysql.com/worklog/task/?id=1524)
- [innodb formats](https://mariadb.com/kb/en/innodb-file-format/)
Innodb uses per table space id.
