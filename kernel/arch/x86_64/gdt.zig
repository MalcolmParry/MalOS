const std = @import("std");
const mem = @import("../../memory.zig");
const arch = @import("x86_64.zig");
const pmm = @import("../../pmm.zig");
const PerCpu = @import("../../PerCpu.zig");

const Ptr = packed struct {
    size_bytes: u16,
    ptr: u64,
};

const Gdt = [7]Desc;
const Desc = u64;
pub const CpuLocal = extern struct {
    gdt: Gdt = undefined,
    io_map_entries: [2]*arch.paging.Entry = undefined,
    padding: [4096 - @sizeOf([7]Desc) - @sizeOf([2]*arch.paging.Entry) - @sizeOf(Tss)]u8 = undefined,
    tss: Tss = .{},
    io_map: [2]mem.Page = undefined,
    io_map_end: u8 = 0xff,

    comptime {
        std.debug.assert(@offsetOf(CpuLocal, "io_map") == 4096);
        std.debug.assert(@offsetOf(CpuLocal, "io_map") - @offsetOf(CpuLocal, "tss") == @sizeOf(Tss));
        std.debug.assert(@offsetOf(CpuLocal, "io_map_end") - @offsetOf(CpuLocal, "io_map") == 4096 * 2);
    }
};

const Tss = extern struct {
    reserved0: u32 = 0,
    rsp0: u64 align(4) = 0,
    rsp1: u64 align(4) = 0,
    rsp2: u64 align(4) = 0,
    reserved1: [8]u8 = @splat(0),
    ist1: u64 align(4) = 0,
    ist2: u64 align(4) = 0,
    ist3: u64 align(4) = 0,
    ist4: u64 align(4) = 0,
    ist5: u64 align(4) = 0,
    ist6: u64 align(4) = 0,
    ist7: u64 align(4) = 0,
    reserved2: [10]u8 = @splat(0),
    iomap_base: u16 = @offsetOf(CpuLocal, "io_map") - @offsetOf(CpuLocal, "tss"),

    comptime {
        std.debug.assert(@sizeOf(Tss) == 0x68);
    }
};

const executable_bit: Desc = 1 << 43;
const code_or_data_bit: Desc = 1 << 44;
const present_bit: Desc = 1 << 47;
const long_mode_bit: Desc = 1 << 53;
const read_write_bit: Desc = 1 << 41;
const dpl3_bits: Desc = 3 << 45;

pub fn init(pc: *PerCpu) void {
    const cpu_local = &pc.arch_specific.gdt;
    const tss = &cpu_local.tss;
    const tss_base: u64 = @intFromPtr(tss);
    const tss_limit: u64 = @offsetOf(CpuLocal, "io_map_end") - @offsetOf(CpuLocal, "tss");

    cpu_local.gdt = .{
        // null desc
        0,
        // kernel code desc
        executable_bit | code_or_data_bit | present_bit | long_mode_bit | read_write_bit,
        // kernel data desc
        present_bit | code_or_data_bit | read_write_bit,
        // user data desc
        present_bit | code_or_data_bit | read_write_bit | dpl3_bits,
        // user code desc
        executable_bit | code_or_data_bit | present_bit | long_mode_bit | read_write_bit | dpl3_bits,
        // task state segment
        (tss_limit & 0xffff) |
            ((tss_base & 0xffff) << 16) |
            (((tss_base >> 16) & 0xff) << 32) |
            present_bit |
            (0x9 << 40) |
            (((tss_limit >> 16) & 0xf) << 48) |
            (((tss_base >> 24) & 0xff) << 56),
        (tss_base >> 32) & 0xffff_ffff,
    };

    const table = arch.paging.getGlobalKernelTable();
    for (&cpu_local.io_map, &cpu_local.io_map_entries) |*page, *entry| {
        const index = @intFromPtr(page) / mem.page_size;
        const l1 = arch.paging.walk(table, index);
        entry.* = &l1.entries[index & 0x1ff];
    }
}

pub fn load() void {
    const pc = PerCpu.get();
    const cpu_local = &pc.arch_specific.gdt;

    const gdtr: Ptr = .{
        .ptr = @intFromPtr(&cpu_local.gdt),
        .size_bytes = @sizeOf(Gdt) - 1,
    };

    asm volatile (
        \\ lgdt (%[gdtr])
        \\
        \\ push $8
        \\ lea 1f(%%rip), %%rax
        \\ push %%rax
        \\ lretq
        \\ 1:
        \\ mov $0x10, %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%ss
        \\
        \\ mov $0x28, %%ax
        \\ ltr %%ax
        :
        : [gdtr] "r" (&gdtr),
        : .{ .rax = true, .memory = true });
}

pub fn setKernelStackPtr(sp: usize) void {
    const cpu_local = &PerCpu.get().arch_specific.gdt;
    cpu_local.tss.rsp0 = sp;
}

pub fn setIoMap(indices: [2]pmm.Index) void {
    const cpu_local = &PerCpu.get().arch_specific.gdt;

    for (&indices, &cpu_local.io_map_entries) |index, entry| {
        entry.* = .{
            .writable = false,
            .user = false,
            .global = true,
            .address = @backingInt(index),
            .disable_cache = false,
            .disable_execute = true,
            .huge = false,
            .present = true,
            .write_through = false,
        };
    }

    for (&cpu_local.io_map) |*page| arch.paging.invalidatePage(page);
}
