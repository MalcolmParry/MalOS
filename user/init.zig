const std = @import("std");
const lib = @import("lib");

pub fn main() noreturn {
    const console = lib.syscall.fopen("/dev/console", .{ .access = .rw }) catch lib.syscall.exit(1);
    for (0..3) |i| {
        lib.syscall.handleClone(console, @enumFromInt(i)) catch {
            panic("failed to clone console fd\n");
        };
    }

    {
        const h0, const h1 = lib.syscall.channelCreatePair() catch panic("failed to create channel pair");
        lib.syscall.channelSend(h0, "msg from channel\n", &.{}) catch panic("failed to send over channel");

        var buffer: [128]u8 = undefined;
        const bytes, _ = lib.syscall.channelReceive(h1, &buffer, &.{}) catch panic("failed to receive over channel");
        lib.writeAll(lib.stdout, 0, buffer[0..bytes]) catch {};
    }

    {
        lib.writeAll(lib.stdout, 0, "hello world\n") catch {};
        const handle = lib.syscall.fopen("/boot/grub/grub.cfg", .{}) catch {
            panic("failed to open file\n");
        };
        defer lib.syscall.handleClose(handle) catch {};

        var buffer: [4096]u8 = undefined;
        const read = lib.syscall.fread(handle, 0, &buffer) catch {
            panic("failed to read file\n");
        };

        lib.writeAll(lib.stdout, 0, buffer[0..read]) catch {};
    }

    lib.syscall.exit(0);
}

fn panic(msg: []const u8) noreturn {
    lib.writeAll(lib.stderr, 0, msg) catch {};
    lib.syscall.exit(1);
}

comptime {
    _ = lib;
}
