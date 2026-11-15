const std = @import("std");
const mem = @import("memory.zig");
const Vmm = @import("Vmm.zig");

pub var boot_stack: []mem.Page = undefined;
pub var max_phys_addr: *mem.PhysPage = undefined;
pub var kernel_phys_range: []mem.Phys(u8) = undefined;
pub var available_phys_ranges: std.ArrayList([]mem.PhysPage) = .initBuffer(&available_phys_range_buffer);
pub var kernel_regions: std.ArrayList(KernelRegion) = .initBuffer(&kernel_region_buffer);
pub var modules: std.ArrayList(Module) = .initBuffer(&module_buffer);
pub var elf_sections: ElfSection.Array = .initFill(null);
pub var display: Display = .none;

var available_phys_range_buffer: [16][]mem.PhysPage = undefined;
var kernel_region_buffer: [16]KernelRegion = undefined;
var module_buffer: [8]Module = undefined;

pub const KernelRegion = struct {
    pages: []mem.Page,
    flags: Vmm.PageFlags,
};

pub const Module = struct {
    pub const max_name_len = 32;

    data: []align(mem.page_size) mem.Phys(u8),
    name_buf: [max_name_len]u8,
    name_len: u8,

    pub inline fn name(this: @This()) []const u8 {
        return this.name_buf[0..this.name_len];
    }
};

pub const Display = union(enum) {
    none,
    vga_text,
};

pub const ElfSection = struct {
    data: []mem.Phys(u8),
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
