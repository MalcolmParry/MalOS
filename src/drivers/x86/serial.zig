const std = @import("std");
const arch = @import("../../arch/arch.zig").current;

const port = 0x3f8;

pub fn init() void {
    arch.outb(port + 1, 0x00);
    arch.outb(port + 3, 0x80);
    arch.outb(port + 0, 0x03);
    arch.outb(port + 1, 0x00);
    arch.outb(port + 3, 0x03);
    arch.outb(port + 2, 0xc7);
    arch.outb(port + 4, 0x0b);
    arch.outb(port + 4, 0x1e);
    arch.outb(port + 0, 0xae);

    if (arch.in(u8, port + 0) != 0xae) {
        @panic("failed to init serial port");
    }

    arch.outb(port + 4, 0x0f);
}

fn isTransmitEmpty() bool {
    return arch.in(u8, port + 5) & 0x20 > 0;
}

pub fn writeByte(x: u8) void {
    while (!isTransmitEmpty()) {
        std.atomic.spinLoopHint();
    }

    arch.outb(port, x);
}

pub fn writeChar(c: u8) void {
    switch (c) {
        '\n' => {
            writeByte('\n');
            writeByte('\r');
        },
        else => writeByte(c),
    }
}

pub fn writeStr(x: []const u8) void {
    for (x) |byte| {
        writeChar(byte);
    }
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
    writeStr(this.buffer[0..this.end]);
    this.end = 0;
    var written: usize = 0;

    for (data[0 .. data.len - 1]) |x| {
        writeStr(x);
        written += x.len;
    }

    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        writeStr(pattern);
        written += pattern.len;
    }

    return written;
}

const writer_vtable: std.Io.Writer.VTable = .{ .drain = &drain };
pub var writer: std.Io.Writer = .{ .vtable = &writer_vtable, .buffer = &.{} };
