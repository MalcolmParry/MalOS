const std = @import("std");
const Mem = @import("Memory.zig");
const Arch = @import("Arch.zig");

pub const PageTable = Arch.Tables.L4;
pub const PageFlags = struct {
    const CacheMode = enum {
        Full,
        // for memory that is read by hardware
        WriteThrough,
        // for io
        Disabled,
    };

    present: bool = true,
    writable: bool = false,
    executable: bool = false,
    kernelOnly: bool = true,
    cacheMode: CacheMode,
};
