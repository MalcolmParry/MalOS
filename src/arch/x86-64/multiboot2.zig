const mem = @import("../../memory.zig");
const pmm = @import("../../pmm.zig");
const vmm = @import("../../vmm.zig");
const vga = @import("vga.zig");
const std = @import("std");

const Phys = mem.Phys;
const page_size = mem.page_size;

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
                _,
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

    const kernel_start: [*]mem.Phys(u8) = @ptrCast(&__KERNEL_START__);
    const kernel_size = @intFromPtr(&__KERNEL_END__) - @intFromPtr(&__KERNEL_START__);
    pmm.kernel_range = kernel_start[0..kernel_size];

    var iter: BootInfoIterater = undefined;
    iter.reset();
    while (iter.next()) |tag| {
        switch (tag.t) {
            .module => {
                const module_tag: *Tag.Module = @ptrCast(tag);

                const name_start: [*]u8 = @ptrFromInt(@intFromPtr(module_tag) + @sizeOf(Tag.Module));
                const name_end: *u8 = @ptrFromInt(@intFromPtr(tag) + tag.size - 1);
                const name: []u8 = name_start[0 .. @intFromPtr(name_end) - @intFromPtr(name_start)];
                if (name.len > mem.Module.max_name_len) @panic("module name too long");

                const len: u32 = module_tag.end - module_tag.start;
                const start: [*]align(page_size) Phys(u8) = @ptrFromInt(module_tag.start);

                const module = mem.modules.addOneBounded() catch @panic("too many modules");
                module.* = .{
                    .phys_range = start[0..len],
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
                while (@intFromPtr(entry) < iter.tag_addr) : (entry = @ptrFromInt(@intFromPtr(entry) + mmap.entry_size)) switch (entry.t) {
                    .available => {
                        var start: usize = std.mem.alignForward(usize, entry.base, mem.page_size);
                        const end: usize = std.mem.alignBackward(usize, entry.base + entry.length, mem.page_size);

                        const min_available_addr = 64 * 1024;
                        if (start < min_available_addr)
                            start = min_available_addr;

                        if (start >= end)
                            continue;

                        const len = (end - start) / mem.page_size;
                        const start_many_ptr: [*]mem.PhysPage = @ptrFromInt(start);
                        const range = start_many_ptr[0..len];

                        pmm.available_ranges.appendBounded(range) catch @panic("too many memory ranges");
                    },
                    .acpi_reclaimable => {
                        std.log.info("ACPI Reclaimable memory at 0x{x} - 0x{x}", .{ entry.base, entry.base + entry.length });
                    },
                    else => {},
                };
            },
            .elf_sections => {
                const elf_sections: *Tag.ElfSections = @ptrCast(tag);
                if (@sizeOf(std.elf.Elf64_Shdr) != elf_sections.entry_size) @panic("wrong elf section header size");
                const sections_many_ptr: [*]align(1) std.elf.Elf64_Shdr = @ptrFromInt(@intFromPtr(elf_sections) + @sizeOf(Tag.ElfSections));
                const sections = sections_many_ptr[0..elf_sections.num];

                for (sections) |section| {
                    if (section.sh_flags & std.elf.SHF_ALLOC == 0) continue;

                    std.log.info("R{c}{c} 0x{x} - 0x{x}", .{
                        @as(u8, if (section.sh_flags & std.elf.SHF_WRITE != 0) 'W' else '-'),
                        @as(u8, if (section.sh_flags & std.elf.SHF_EXECINSTR != 0) 'X' else '-'),
                        section.sh_addr,
                        section.sh_addr + section.sh_size,
                    });

                    const start = std.mem.alignBackward(u64, section.sh_addr, mem.page_size);
                    const end = std.mem.alignForward(u64, section.sh_addr + section.sh_size, mem.page_size);

                    if (start < mem.kernel_virt_base) continue;

                    const start_ptr: [*]mem.Page = @ptrFromInt(start);
                    const page_count = (end - start) / mem.page_size;

                    vmm.kernel_regions.appendBounded(.{
                        .pages = start_ptr[0..page_count],
                        .flags = .{
                            .cache_mode = .full,
                            .writable = section.sh_flags & std.elf.SHF_WRITE > 0,
                            .executable = section.sh_flags & std.elf.SHF_EXECINSTR > 0,
                            .user = false,
                            .global = false,
                        },
                    }) catch @panic("too many elf kernel sections");
                }
            },
            .load_base_addr => {
                const load_base_addr: *Tag.LoadBaseAddr = @ptrCast(tag);
                if (load_base_addr.addr != @intFromPtr(pmm.kernel_range.ptr))
                    @panic("wrong kernel load address");
            },
            else => std.log.info("multiboot tag: {s}", .{@tagName(tag.t)}),
        }
    }

    vmm.kernel_regions.appendBounded(.{ .pages = mem.pageSliceFromBytesInclusive(std.mem.asBytes(vga.video_memory)), .flags = .{
        .cache_mode = .disabled,
        .writable = true,
        .executable = false,
        .user = false,
        .global = false,
    } }) catch @panic("too many elf kernel sections");
}
