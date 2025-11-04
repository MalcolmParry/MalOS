const mem = @import("../../memory.zig");
const pmm = @import("../../pmm.zig");
const std = @import("std");

extern var phys_multiboot_info: *mem.Phys(Info);
var multiboot_info: *Info = undefined;

const Info = packed struct {
    totalSize: u32,
    reserved: u32,
};

const Tag = extern struct {
    const MMap = extern struct {
        const Entry = extern struct {
            const Type = enum(u32) {
                available = 1,
                reserved = 2,
                acpi_reclaimable = 3,
                nvs = 4,
                bad = 5,
            };

            base: u64,
            length: u64,
            t: Entry.Type,
        };

        tag: Tag,
        entry_size: u32,
        version: u32,
        entries: Entry,
    };

    const Module = extern struct {
        tag: Tag,
        start: u32,
        end: u32,
    };

    const ElfSections = extern struct {
        tag: Tag,
        num: u32,
        entry_size: u32,
        str_table_index: u32,
    };

    const LoadBaseAddr = extern struct {
        tag: Tag,
        addr: u32,
    };

    const Type = enum(u32) {
        end,
        cmd_line,
        boot_loader_name,
        module,
        mem_info,
        boot_dev,
        mmap,
        vbe,
        framebuffer,
        elf_sections,
        apm,
        efi32,
        efi64,
        smbios,
        acpi_old,
        acpi_new,
        network,
        efi_mmap,
        efi_bs,
        efi32_ih,
        efi64_ih,
        load_base_addr,
    };

    t: Type,
    size: u32,
};

const BootInfoIterater = struct {
    tag_addr: u64,

    fn next(this: *@This()) ?*align(8) Tag {
        const tag: *align(8) Tag = @ptrFromInt(this.tag_addr);
        this.tag_addr += (tag.size + 7) & ~@as(u64, 7);
        if (this.tag_addr > @intFromPtr(multiboot_info) + 8 + multiboot_info.totalSize)
            return null;
        if (tag.t == .end)
            return null;
        return tag;
    }

    fn reset(this: *@This()) void {
        this.tag_addr = @intFromPtr(multiboot_info) + 8;
    }
};

extern var __KERNEL_START__: anyopaque;
extern var __KERNEL_END__: anyopaque;

pub fn initBootInfo() void {
    multiboot_info = @ptrFromInt(@intFromPtr(phys_multiboot_info) + mem.kernel_virt_base);
    pmm.kernel_range = mem.PhysRange.fromStartAndEnd(@intFromPtr(&__KERNEL_START__), @intFromPtr(&__KERNEL_END__));

    var iter: BootInfoIterater = undefined;
    iter.reset();
    while (iter.next()) |tag| {
        switch (tag.t) {
            .module => {
                const module_tag: *Tag.Module = @ptrCast(tag);

                const name_start: [*]u8 = @ptrFromInt(@intFromPtr(module_tag) + @sizeOf(Tag.Module));
                const name_end: *u8 = @ptrFromInt(@intFromPtr(tag) + tag.size - 1);
                const name: []u8 = name_start[0 .. @intFromPtr(name_end) - @intFromPtr(name_start)];

                const len: u32 = module_tag.end - module_tag.start;
                if (name.len > mem.Module.max_name_len) @panic("module name too long");

                const module = mem.modules.addOneBounded() catch @panic("too many modules");
                module.* = .{
                    .phys_range = .{ .base = module_tag.start, .len = len },
                    .data = null,
                    .name_buf = undefined,
                    .name_len = name.len,
                };

                @memcpy(module.name_buf[0..name.len], name);
            },
            .mmap => {
                const mmap: *Tag.MMap = @ptrCast(tag);
                if (mmap.version != 0)
                    @panic("wrong mmap version");

                var entry: *align(1) Tag.MMap.Entry = @ptrFromInt(@intFromPtr(mmap) + @sizeOf(Tag.MMap));
                while (@intFromPtr(entry) < iter.tag_addr) : (entry = @ptrFromInt(@intFromPtr(entry) + mmap.entry_size)) {
                    if (entry.t == .acpi_reclaimable)
                        std.log.info("ACPI Reclaimable memory at 0x{x} - 0x{x}\n", .{ entry.base, entry.base + entry.length });

                    if (entry.t != .available)
                        continue;

                    var start: usize = std.mem.alignForward(usize, entry.base, mem.page_size);
                    const end: usize = std.mem.alignBackward(usize, entry.base + entry.length, mem.page_size);

                    const min_available_addr = 64 * 1024;
                    if (start < min_available_addr)
                        start = min_available_addr;

                    if (start >= end)
                        continue;

                    const range: mem.PhysRange = .{
                        .base = start,
                        .len = end - start,
                    };

                    pmm.available_ranges.appendBounded(range) catch @panic("not enough memory ranges");
                }
            },
            .elf_sections => {
                const elf_sections: *Tag.ElfSections = @ptrCast(tag);
                if (@sizeOf(std.elf.Elf64_Shdr) != elf_sections.entry_size) @panic("wrong elf section header size");
                const sections_many_ptr: [*]align(1) std.elf.Elf64_Shdr = @ptrFromInt(@intFromPtr(elf_sections) + @sizeOf(Tag.ElfSections));
                const sections = sections_many_ptr[0..elf_sections.num];

                for (sections) |section| {
                    if (section.sh_flags & std.elf.SHF_ALLOC == 0) continue;
                    std.log.info("R{c}{c} ", .{
                        @as(u8, if (section.sh_flags & std.elf.SHF_WRITE != 0) 'W' else '-'),
                        @as(u8, if (section.sh_flags & std.elf.SHF_EXECINSTR != 0) 'X' else '-'),
                    });
                    std.log.info("0x{x} - 0x{x}\n", .{ section.sh_addr, section.sh_addr + section.sh_size });
                }
            },
            .load_base_addr => {
                const load_base_addr: *Tag.LoadBaseAddr = @ptrCast(tag);
                if (load_base_addr.addr != pmm.kernel_range.base)
                    @panic("wrong kernel load address");
            },
            else => std.log.info("multiboot tag: {s}\n", .{@tagName(tag.t)}),
        }
    }
}
