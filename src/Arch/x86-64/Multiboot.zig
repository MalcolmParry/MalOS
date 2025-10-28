const mem = @import("../../Memory.zig");
const std = @import("std");
const vga = @import("VGA.zig");

extern var phys_multiboot_info: *mem.Phys(Info);
var multiboot_info: *Info = undefined;

const Info = packed struct {
    totalSize: u32,
    reserved: u32,
};

const Tag = packed struct {
    const MMap = packed struct {
        const Entry = packed struct {
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
            pad: u32 = 0,
        };

        entry_size: u32,
        version: u32,
    };

    const Module = packed struct {
        start: u32,
        end: u32,
    };

    const LoadBaseAddr = u32;

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

    fn next(this: *@This()) ?*align(1) Tag {
        const tag: *align(1) Tag = @ptrFromInt(this.tag_addr);
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

var phys_modules: [mem.max_modules]mem.PhysModule = undefined;
var raw_available_ranges: [mem.max_available_ranges]mem.PhysRange = undefined;

pub fn initBootInfo(alloc: std.mem.Allocator) void {
    multiboot_info = @ptrFromInt(@intFromPtr(phys_multiboot_info) + mem.kernel_virt_base);
    mem.kernel_range = mem.PhysRange.fromStartAndEnd(@intFromPtr(&__KERNEL_START__), @intFromPtr(&__KERNEL_END__));

    var module_index: u32 = 0;
    var available_ranges = std.ArrayList(mem.PhysRange).initBuffer(&raw_available_ranges);

    var iter: BootInfoIterater = undefined;
    iter.reset();
    while (iter.next()) |tag| {
        switch (tag.t) {
            .module => {
                const module: *align(1) Tag.Module = @ptrFromInt(@intFromPtr(tag) + @sizeOf(Tag));

                const name_start: [*]u8 = @ptrFromInt(@intFromPtr(module) + @sizeOf(Tag.Module));
                const name_end: *u8 = @ptrFromInt(@intFromPtr(tag) + tag.size - 1);
                const name: []u8 = name_start[0 .. @intFromPtr(name_end) - @intFromPtr(name_start)];

                const len: u32 = module.end - module.start + 1;

                phys_modules[module_index] = .{
                    .phys_range = .{ .base = module.start, .len = len },
                    .name = alloc.dupe(u8, name) catch @panic("out of memory"),
                };

                module_index += 1;
            },
            .mmap => {
                const mmap: *align(1) Tag.MMap = @ptrFromInt(@intFromPtr(tag) + @sizeOf(Tag));
                if (mmap.version != 0)
                    @panic("wrong mmap version");

                var entry: *align(1) Tag.MMap.Entry = @ptrFromInt(@intFromPtr(mmap) + @sizeOf(Tag.MMap));
                while (@intFromPtr(entry) < iter.tag_addr) : (entry = @ptrFromInt(@intFromPtr(entry) + mmap.entry_size)) {
                    if (entry.t == .acpi_reclaimable)
                        std.log.info("ACPI Reclaimable memory at 0x{x} - 0x{x}\n", .{ entry.base, entry.base + entry.length });

                    if (entry.t != .available)
                        continue;

                    // std.log.info("mem free: 0x{x} - 0x{x}\n", .{ entry.base, entry.base + entry.length });
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

                    available_ranges.appendBounded(range) catch @panic("not enough memory ranges");
                }
            },
            .load_base_addr => {
                const load_base_addr: *align(1) Tag.LoadBaseAddr = @ptrFromInt(@intFromPtr(tag) + @sizeOf(Tag));
                if (load_base_addr.* != mem.kernel_range.base)
                    @panic("wrong kernel load address");
            },
            else => std.log.info("multiboot tag: {s}\n", .{@tagName(tag.t)}),
        }
    }

    mem.phys_modules = phys_modules[0..module_index];

    reserveRegion(&available_ranges, mem.kernel_range);
    reserveRegion(&available_ranges, vga.getPhysRange());
    for (mem.phys_modules) |module| {
        reserveRegion(&available_ranges, module.phys_range);
    }

    mem.available_ranges = available_ranges;
}

fn reserveRegion(available_ranges: *std.ArrayList(mem.PhysRange), reserved: mem.PhysRange) void {
    const res_aligned = reserved.alignOutwards(mem.page_size);

    var i: u32 = 0;
    while (i < available_ranges.items.len) {
        const range = available_ranges.items[i];
        var start = range.base;
        var end = range.base + range.len;

        if (res_aligned.addrInRange(start))
            start = res_aligned.end();

        if (res_aligned.addrInRange(end))
            end = res_aligned.base;

        if (start >= end) {
            _ = available_ranges.swapRemove(i);
            continue;
        }

        const newRange: mem.PhysRange = .{ .base = start, .len = end - start };

        if (newRange.addrInRange(res_aligned.base)) {
            const additional: mem.PhysRange = .{
                .base = res_aligned.end(),
                .len = end - res_aligned.end(),
            };

            available_ranges.appendBounded(additional) catch @panic("not enough memory ranges");
            end = res_aligned.base;
        }

        available_ranges.items[i] = .{ .base = start, .len = end - start };
        if (available_ranges.items[i].len <= mem.page_size) {
            _ = available_ranges.swapRemove(i);
            continue;
        }

        i += 1;
    }
}
