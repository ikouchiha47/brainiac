const std = @import("std");

const LockMode = enum {
    Shared,
    Exclusive,
};

pub const LockInfo = struct {
    mode: LockMode,
    holder: u64,
    wait_queue: std.ArrayList(u64),
};
