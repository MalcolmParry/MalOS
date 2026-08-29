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

    arch.outb(pic1_cmd, icw1_init | icw1_icw4);
    arch.ioWait();
    arch.outb(pic2_cmd, icw1_init | icw1_icw4);
    arch.ioWait();

    arch.outb(pic1_data, offset1);
    arch.ioWait();
    arch.outb(pic2_data, offset2);
    arch.ioWait();

    arch.outb(pic1_data, 1 << 2);
    arch.ioWait();
    arch.outb(pic2_data, 2);
    arch.ioWait();

    arch.outb(pic1_data, icw4_8086);
    arch.ioWait();
    arch.outb(pic2_data, icw4_8086);
    arch.ioWait();

    // unmask timer
    arch.outb(pic1_data, 0b1111_1110);
    arch.outb(pic2_data, 0b1111_1111);
}

pub fn eoi() void {
    arch.outb(pic1_cmd, 0x20);
}
