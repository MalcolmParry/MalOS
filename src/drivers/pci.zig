const std = @import("std");
const builtin = @import("builtin");
const arch = @import("../arch/arch.zig").current;
const Ahci = @import("Ahci.zig");

pub const Addr = struct {
    bus: u8,
    device: u5,
    func: u3,

    pub fn format(addr: Addr, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{x:0>2}:{x:0>2}.{x:0>1}", .{ addr.bus, addr.device, addr.func });
    }
};

pub const CmdRegister = packed struct(u16) {
    io_space: bool,
    mem_space: bool,
    bus_master: bool,
    special_cycles: bool,
    mem_write_and_invalidate: bool,
    vga_palette_snoop: bool,
    parity_error_response: bool,
    reserved: u1,
    serr_enable: bool,
    fast_back_to_back: bool,
    int_disable: bool,
    reserved2: u5,
};

fn getAddr(addr: Addr, offset: u8) u32 {
    std.debug.assert(offset % 4 == 0);
    const lbus: u32 = addr.bus;
    const ldevice: u32 = addr.device;
    const lfunc: u32 = addr.func;

    return (lbus << 16) | (ldevice << 11) | (lfunc << 8) | offset | 0x8000_0000;
}

pub fn read32(addr: Addr, offset: u8) u32 {
    std.debug.assert(offset % 4 == 0);

    switch (builtin.cpu.arch) {
        .x86, .x86_64 => {
            arch.outl(0xcf8, getAddr(addr, offset));
            return arch.in(u32, 0xcfc);
        },
        else => @compileError("cpu not supported"),
    }
}

pub fn read16(addr: Addr, offset: u8) u16 {
    std.debug.assert(offset % 2 == 0);
    return @truncate(read32(addr, offset & 0xfc) >> @truncate((offset & 2) * 8));
}

pub fn read8(addr: Addr, offset: u8) u8 {
    return @truncate(read32(addr, offset & 0xfc) >> @truncate((offset & 3) * 8));
}

pub fn write16(addr: Addr, offset: u8, val: u16) void {
    std.debug.assert(offset % 2 == 0);
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => {
            arch.outl(0xcf8, getAddr(addr, offset & 0xfc));
            arch.outw(@as(u16, 0xcfc) + (offset & 2), val);
        },
        else => @compileError("unsupported arch"),
    }
}

pub fn check() void {
    checkBus(0);
}

fn checkBus(bus: u8) void {
    for (0..32) |device| {
        checkDevice(bus, @intCast(device));
    }
}

fn checkDevice(bus: u8, device: u5) void {
    {
        const addr: Addr = .{
            .bus = bus,
            .device = device,
            .func = 0,
        };

        const vendor_id = read16(addr, 0);
        if (vendor_id == 0xffff) return;
        checkFunc(addr);
        if (read8(addr, 0xe) & 0x80 == 0) return;
    }

    for (1..8) |ufunc| {
        const addr: Addr = .{
            .bus = bus,
            .device = device,
            .func = @intCast(ufunc),
        };

        const vendor_id = read16(addr, 0);
        if (vendor_id == 0xffff) continue;
        checkFunc(addr);
    }
}

fn checkFunc(addr: Addr) void {
    const r0 = read32(addr, 0x0);
    const r2 = read32(addr, 0x8);
    const r3 = read32(addr, 0xc);

    const vendor: u16 = @truncate(r0);
    const prog_if: u8 = @truncate(r2 >> 8);
    const subclass: u8 = @truncate(r2 >> 16);
    const class: u8 = @truncate(r2 >> 24);
    const header_type: u7 = @intCast((r3 >> 16) & 0x7f);

    std.log.info("pci {x:0>2}:{x:0>2}.{x:0>1} h:{x:0>2} v:{x:0>4} c:{x:0>2} sc:{x:0>2} pif:{x:0>2}", .{
        addr.bus, addr.device, addr.func, header_type, vendor, class, subclass, prog_if,
    });

    if (header_type == 1) {
        const secondary_bus = read8(addr, 0x19);
        checkBus(secondary_bus);
    }

    if (class == 1 and subclass == 6) {
        Ahci.initController(addr) catch |err| {
            std.log.err("failed to init ahci controller at pci {f}: {}", .{ addr, err });
        };
    }
}
