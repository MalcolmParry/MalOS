const std = @import("std");
const mem = @import("memory.zig");
const vmm = @import("vmm.zig");
const BootInfo = @This();

kernel_phys_range: []mem.Phys(u8),
available_phys_range_buffer: [16][]mem.PhysPage,
available_phys_range_count: u16,
kernel_region_buffer: [16]KernelRegion,
kernel_region_count: u16,
module_buffer: [8]mem.Module,
module_count: u16,

pub const KernelRegion = struct {
    pages: []mem.Page,
    flags: vmm.PageFlags,
};

pub fn availablePhysRanges(info: *const BootInfo) []const []mem.PhysPage {
    return info.available_phys_range_buffer[0..info.available_phys_range_count];
}

pub fn kernelRegions(info: *const BootInfo) []const KernelRegion {
    return info.kernel_region_buffer[0..info.kernel_region_count];
}

pub fn modules(info: *const BootInfo) []const mem.Module {
    return info.module_buffer[0..info.module_count];
}
