const arch = @import("../../arch.zig").current;

pub const pit_hz = 1_193_182;
pub const divisor = pit_hz / 100;
pub const period_ns = 9_999_315;

const ports = struct {
    const ch0: u8 = 0x40;
    const ch1: u8 = 0x41;
    const ch2: u8 = 0x42;
    const cmd: u8 = 0x43;
};

const Command = packed struct(u8) {
    const OpMode = enum(u3) {
        int_on_terminal_count = 0,
    };

    const AccessMode = enum(u2) {
        latch_count = 0,
        low_only = 1,
        high_only = 2,
        low_high = 3,
    };

    bcd_mode: bool = false,
    op_mode: OpMode,
    access_mode: AccessMode,
    channel: u2,
};

pub fn read_count(channel: u2) u16 {
    arch.out(ports.cmd, @as(Command, .{}));

    const low: u16 = arch.in(u8, ports.ch0 + channel);
    const high: u16 = arch.in(u8, ports.ch0 + channel);

    return (high << 8) | low;
}

pub fn write_count(channel: u2, count: u16) void {
    arch.outb(ports.ch0 + channel, @truncate(count));
    arch.outb(ports.ch0 + channel, @truncate(count >> 8));
}

pub fn init() void {
    arch.outb(ports.cmd, 0b0011_0100);

    arch.outb(ports.ch0, @truncate(divisor));
    arch.outb(ports.ch0, @truncate(divisor >> 8));
}
