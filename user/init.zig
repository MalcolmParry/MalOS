const std = @import("std");
const lib = @import("lib");

pub fn main() noreturn {
    lib.syscall.debugPrint("hello world\n") catch {};
    const fd = lib.syscall.fopen("/boot/grub/grub.cfg") catch {
        panic("failed to open file\n");
    };

    var buffer: [4096]u8 = undefined;
    const read = lib.syscall.fread(fd, &buffer) catch {
        panic("failed to read file\n");
    };

    lib.syscall.debugPrint(buffer[0..read]) catch {};

    spinwait();
}

fn panic(msg: []const u8) noreturn {
    lib.syscall.debugPrint(msg) catch {};
    spinwait();
}

fn spinwait() noreturn {
    while (true) {
        std.atomic.spinLoopHint();
    }
}

comptime {
    _ = lib;
}
