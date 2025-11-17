const std = @import("std");
const arch = @import("arch.zig");

pub const PageFlags = packed struct {
    const CacheMode = enum(u4) {
        full,
        // for memory that is read by hardware
        write_through,
        // for io
        disabled,
    };

    cache_mode: CacheMode,
    writable: bool,
    executable: bool,
    kernel_only: bool,
    global: bool,
};
