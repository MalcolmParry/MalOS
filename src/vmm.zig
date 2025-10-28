const std = @import("std");
const arch = @import("arch.zig");

pub const PageFlags = struct {
    const CacheMode = enum {
        full,
        // for memory that is read by hardware
        write_through,
        // for io
        disabled,
    };

    present: bool = true,
    writable: bool,
    executable: bool,
    kernel_only: bool,
    cache_mode: CacheMode,
    global: bool,
};
