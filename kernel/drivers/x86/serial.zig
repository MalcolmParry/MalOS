const std = @import("std");
const arch = @import("../../arch/arch.zig").current;

const port = 0x3f8;

pub fn init() bool {
    const divisor: u16 = 1;

    arch.outb(port + 1, 0x00);
    arch.outb(port + 3, 0x80);
    arch.outb(port + 0, @truncate(divisor & 0xff));
    arch.outb(port + 1, @truncate(divisor >> 8));
    arch.outb(port + 3, 0x03);
    arch.outb(port + 2, 0xc7);
    arch.outb(port + 4, 0x0b);
    arch.outb(port + 4, 0x1e);
    arch.outb(port + 0, 0xae);

    for (0..100_000) |_| {
        if (serialReceived()) break;
    }
    if (arch.in(u8, port + 0) != 0xae) return false;

    arch.outb(port + 4, 0x0f);
    return true;
}

fn isTransmitEmpty() bool {
    return arch.in(u8, port + 5) & 0x20 > 0;
}

pub fn writeByte(byte: u8) void {
    while (!isTransmitEmpty()) {
        std.atomic.spinLoopHint();
    }

    arch.outb(port, byte);
}

pub fn write(data: []const u8) void {
    for (data) |byte| writeByte(byte);
}

fn serialReceived() bool {
    return arch.in(u8, port + 5) & 1 > 0;
}

pub fn read() u8 {
    while (!serialReceived()) {
        std.atomic.spinLoopHint();
    }

    return arch.in(u8, port);
}

fn drain(this: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
    write(this.buffer[0..this.end]);
    this.end = 0;
    var written: usize = 0;

    for (data[0 .. data.len - 1]) |x| {
        write(x);
        written += x.len;
    }

    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        write(pattern);
        written += pattern.len;
    }

    return written;
}

const writer_vtable: std.Io.Writer.VTable = .{ .drain = &drain };
pub var writer: std.Io.Writer = .{ .vtable = &writer_vtable, .buffer = &.{} };
