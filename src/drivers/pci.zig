const std = @import("std");
const builtin = @import("builtin");
const arch = @import("../arch/arch.zig").current;

pub fn readU32(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    std.debug.assert(offset % 4 == 0);

    switch (builtin.cpu.arch) {
        .x86, .x86_64 => {
            const lbus: u32 = bus;
            const lslot: u32 = slot;
            const lfunc: u32 = func;

            const addr = (lbus << 16) | (lslot << 11) | (lfunc << 8) | offset | 0x8000_0000;
            arch.outl(0xcf8, addr);
            return arch.in(u32, 0xcfc);
        },
        else => @compileError("cpu not supported"),
    }
}

pub fn readU16(bus: u8, slot: u8, func: u8, offset: u8) u16 {
    std.debug.assert(offset % 2 == 0);
    return @truncate(readU32(bus, slot, func, offset & 0xfc) >> @truncate((offset & 2) * 8));
}

pub fn readU8(bus: u8, slot: u8, func: u8, offset: u8) u8 {
    return @truncate(readU32(bus, slot, func, offset & 0xfc) >> @truncate((offset & 3) * 8));
}

pub fn check() void {
    checkBus(0);
}

fn checkBus(bus: u8) void {
    for (0..32) |device| {
        checkDevice(bus, @intCast(device));
    }
}

fn checkDevice(bus: u8, device: u8) void {
    {
        const vendor_id = readU16(bus, device, 0, 0);
        if (vendor_id == 0xffff) return;
        checkFunc(bus, device, 0);
    }

    if (readU8(bus, device, 0, 0xe) & 0x80 == 0) return;
    for (1..8) |ufunc| {
        const func: u8 = @intCast(ufunc);
        const vendor_id = readU16(bus, device, func, 0);
        if (vendor_id == 0xffff) continue;
        checkFunc(bus, device, func);
    }
}

fn checkFunc(bus: u8, device: u8, func: u8) void {
    const r0 = readU32(bus, device, func, 0x0);
    const r2 = readU32(bus, device, func, 0x8);
    const r3 = readU32(bus, device, func, 0xc);

    const vendor: u16 = @truncate(r0);
    const prog_if: u8 = @truncate(r2 >> 8);
    const subclass: u8 = @truncate(r2 >> 16);
    const class: u8 = @truncate(r2 >> 24);
    const header_type: u7 = @intCast((r3 >> 16) & 0x7f);

    std.log.info("pci b:{x:0>2} d:{x:0>2} f:{x:0>2} h:{x:0>2} v:{x:0>4} c:{x:0>2} sc:{x:0>2} pif:{x:0>2}", .{
        bus, device, func, header_type, vendor, class, subclass, prog_if,
    });

    if (header_type == 1) {
        const secondary_bus = readU8(bus, device, func, 0x19);
        checkBus(secondary_bus);
    }
}
