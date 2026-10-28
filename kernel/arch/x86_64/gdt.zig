const std = @import("std");
const mem = @import("../../memory.zig");
const arch = @import("x86_64.zig");
const pmm = @import("../../pmm.zig");

const Ptr = packed struct {
    size_bytes: u16,
    ptr: u64,
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
    iomap_base: u16 = @offsetOf(TssAndIoMap, "io_map0") - @offsetOf(TssAndIoMap, "tss"),

    comptime {
        std.debug.assert(@sizeOf(Tss) == 0x68);
    }
};

const TssAndIoMap = extern struct {
    padding: [4096 - @sizeOf(Tss)]u8 = undefined,
    tss: Tss = .{},
    io_map0: mem.Page = .{ .bytes = @splat(0xff) },
    io_map1: mem.Page = .{ .bytes = @splat(0xff) },
    io_map_end: u8 = 0xff,
};

var gdt: [7]Desc = undefined;
pub var tss_and_io_map: TssAndIoMap = .{};
const Desc = u64;
const executable_bit: Desc = 1 << 43;
const code_or_data_bit: Desc = 1 << 44;
const present_bit: Desc = 1 << 47;
const long_mode_bit: Desc = 1 << 53;
const read_write_bit: Desc = 1 << 41;
const dpl3_bits: Desc = 3 << 45;

pub fn init() void {
    const tss = &tss_and_io_map.tss;
    const tss_base: u64 = @intFromPtr(tss);
    const tss_limit: u64 = @offsetOf(TssAndIoMap, "io_map_end") - @offsetOf(TssAndIoMap, "tss");

    gdt = .{
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

    const gdtr: Ptr = .{
        .ptr = @intFromPtr(&gdt),
        .size_bytes = @sizeOf(Desc) * gdt.len - 1,
    };

    asm volatile (
        \\lgdt (%[addr])
        :
        : [addr] "r" (&gdtr),
        : .{ .memory = true });

    asm volatile (
        \\push $0x08
        \\lea 1f(%%rip), %%rax
        \\push %%rax
        \\lretq
        \\1:
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        ::: .{ .rax = true, .memory = true });

    asm volatile (
        \\mov $0x28, %%ax
        \\ltr %%ax
        ::: .{ .ax = true });
}

pub var io_map_entry0: *arch.paging.Entry = undefined;
pub var io_map_entry1: *arch.paging.Entry = undefined;

pub fn setKernelStackPtr(sp: usize) void {
    tss_and_io_map.tss.rsp0 = sp;
}

pub fn setIoMap(p0: pmm.Index, p1: pmm.Index) void {
    io_map_entry0.* = .{
        .writable = false,
        .user = false,
        .global = true,
        .address = @intFromEnum(p0),
        .disable_cache = false,
        .disable_execute = true,
        .huge = false,
        .present = true,
        .write_through = false,
        .accessed = false,
    };

    io_map_entry1.* = .{
        .writable = false,
        .user = false,
        .global = true,
        .address = @intFromEnum(p1),
        .disable_cache = false,
        .disable_execute = true,
        .huge = false,
        .present = true,
        .write_through = false,
        .accessed = false,
    };

    arch.paging.invalidatePage(&tss_and_io_map.io_map0);
    arch.paging.invalidatePage(&tss_and_io_map.io_map1);
}
