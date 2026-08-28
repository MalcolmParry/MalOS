const arch = @import("x86_64.zig");

const pic1_cmd = 0x20;
const pic1_data = pic1_cmd + 1;
const pic2_cmd = 0xa0;
const pic2_data = pic2_cmd + 1;

const icw1_init = 0x10;
const icw1_icw4 = 0x01;

const icw4_8086 = 0x01;

pub fn init() void {
    const offset1 = 32;
    const offset2 = offset1 + 8;

    arch.out(pic1_cmd, @as(u8, icw1_init | icw1_icw4));
    arch.ioWait();
    arch.out(pic2_cmd, @as(u8, icw1_init | icw1_icw4));
    arch.ioWait();

    arch.out(pic1_data, @as(u8, offset1));
    arch.ioWait();
    arch.out(pic2_data, @as(u8, offset2));
    arch.ioWait();

    arch.out(pic1_data, @as(u8, 1 << 2));
    arch.ioWait();
    arch.out(pic2_data, @as(u8, 2));
    arch.ioWait();

    arch.out(pic1_data, @as(u8, icw4_8086));
    arch.ioWait();
    arch.out(pic2_data, @as(u8, icw4_8086));
    arch.ioWait();

    // unmask timer
    arch.out(pic1_data, @as(u8, 0b1111_1110));
    arch.out(pic2_data, @as(u8, 0b1111_1111));
}

pub fn eoi() void {
    arch.out(pic1_cmd, @as(u8, 0x20));
}
