const std = @import("std");

pub const page_size = 4096;
pub const kernel_virt_base: u64 = 0xffff_ffff_c000_0000;

pub const interrupt = @import("interrupt.zig");
pub const multiboot = @import("multiboot2.zig");
pub const paging = @import("paging.zig");
pub const cpu = @import("cpu.zig");

pub const initBootInfo = multiboot.initBootInfo;

pub const halt = cpu.halt;
pub const spinWait = cpu.spinWait;

pub const in = cpu.in;
pub const out = cpu.out;
pub const ioWait = cpu.ioWait;

pub fn kernelEntry() callconv(.{ .x86_64_sysv = .{ .incoming_stack_alignment = 16 } }) noreturn {
    @import("../../main.zig").kernelMain();
}

comptime {
    @export(&kernelEntry, .{ .name = "kernelEntry" });
}
