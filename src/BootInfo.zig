const std = @import("std");
const mem = @import("memory.zig");
const Vmm = @import("Vmm.zig");
const BootInfo = @This();

max_phys_addr: *mem.PhysPage,
kernel_phys_range: []mem.Phys(u8),
available_phys_range_buffer: [16][]mem.PhysPage,
available_phys_range_count: u16,
kernel_region_buffer: [16]KernelRegion,
kernel_region_count: u16,
module_buffer: [8]mem.Module,
module_count: u16,
vga_text_info: ?VgaTextInfo,
elf_sections: ElfSection.Array,

pub const KernelRegion = struct {
    pages: []mem.Page,
    flags: Vmm.PageFlags,
};

pub const VgaTextInfo = struct {
    phys_addr: u64,
    width: u16,
    height: u16,
    pitch: u32,
};

pub const ElfSection = struct {
    phys_range: []mem.Phys(u8),
    data: []u8 = &.{},
    header: std.elf.Elf64.Shdr,

    pub const Id = enum {
        // dwarf
        debug_info,
        debug_abbrev,
        debug_str,
        debug_str_offsets,
        debug_line,
        debug_line_str,
        debug_ranges,
        debug_loclists,
        debug_rnglists,
        debug_addr,
        debug_names,

        symtab,
        strtab,
        // gnu_debuglink,
        // eh_frame,
        // debug_frame,
    };

    pub const Array = std.EnumArray(Id, ?ElfSection);
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
