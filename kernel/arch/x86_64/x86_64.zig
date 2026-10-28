const std = @import("std");
const debug = @import("../../debug.zig");
const gdt = @import("gdt.zig");

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
pub const outb = cpu.outb;
pub const outw = cpu.outw;
pub const outl = cpu.outl;
pub const ioWait = cpu.ioWait;

const user_copy = @import("user_copy.zig");
pub const copyFromUser = user_copy.copyFromUser;
pub const copyToUser = user_copy.copyToUser;

pub fn kernelEntry() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    @import("../../main.zig").kernelMain() catch |err| {
        debug.dumpErrorAndPanic(err);
    };
}

comptime {
    @export(&kernelEntry, .{ .name = "kernelEntry" });
}
