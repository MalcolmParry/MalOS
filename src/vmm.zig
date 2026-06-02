const std = @import("std");
const arch = @import("arch.zig");
const mem = @import("memory.zig");

var kernel_regions_buffer: [16]KernelRegion = undefined;
pub var kernel_regions: std.ArrayList(KernelRegion) = .initBuffer(&kernel_regions_buffer);

pub const KernelRegion = struct {
    pages: mem.PageSlice,
    flags: PageFlags,
};

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
