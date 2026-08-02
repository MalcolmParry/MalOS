const std = @import("std");
const arch = @import("arch.zig");
const Spinlock = @import("../../Spinlock.zig");

const port = 0x3f8;

pub fn init() void {
    arch.out(port + 1, @as(u8, 0x00));
    arch.out(port + 3, @as(u8, 0x80));
    arch.out(port + 0, @as(u8, 0x03));
    arch.out(port + 1, @as(u8, 0x00));
    arch.out(port + 3, @as(u8, 0x03));
    arch.out(port + 2, @as(u8, 0xc7));
    arch.out(port + 4, @as(u8, 0x0b));
    arch.out(port + 4, @as(u8, 0x1e));
    arch.out(port + 0, @as(u8, 0xae));

    if (arch.in(u8, port + 0) != 0xae) {
        @panic("failed to init serial port");
    }

    arch.out(port + 4, @as(u8, 0x0f));
}

fn isTransmitEmpty() bool {
    return arch.in(u8, port + 5) & 0x20 > 0;
}

pub fn writeByte(x: u8) void {
    while (!isTransmitEmpty()) {
        std.atomic.spinLoopHint();
    }

    arch.out(port, x);
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
pub var term: std.Io.Terminal = .{ .writer = &writer, .mode = .escape_codes };
pub var writer_spinlock: Spinlock = .{};
