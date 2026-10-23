const std = @import("std");
const lib = @import("lib");

pub fn main() noreturn {
    for (0..3) |i| {
        const fd = lib.syscall.fopen("/dev/console") catch spinwait();
        if (@intFromEnum(fd) != i) spinwait();
    }

    {
        lib.writeAll(lib.stdout, 0, "hello world\n") catch {};
        const fd = lib.syscall.fopen("/boot/grub/grub.cfg") catch {
            panic("failed to open file\n");
        };
        defer lib.syscall.fclose(fd) catch {};

        var buffer: [4096]u8 = undefined;
        const read = lib.syscall.fread(fd, 0, &buffer) catch {
            panic("failed to read file\n");
        };

        lib.writeAll(lib.stdout, 0, buffer[0..read]) catch {};
    }

    spinwait();
}

fn panic(msg: []const u8) noreturn {
    lib.writeAll(lib.stderr, 0, msg) catch {};
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
