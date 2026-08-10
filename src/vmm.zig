const std = @import("std");
const arch = @import("arch.zig");
const mem = @import("memory.zig");

pub const PageFlags = packed struct {
    const CacheMode = enum(u2) {
        full,
        // for memory that is read by hardware
        write_through,
        // for io
        disabled,
    };

    cache_mode: CacheMode,
    writable: bool,
    executable: bool,
    user: bool,
    global: bool,
};
