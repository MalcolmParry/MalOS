const std = @import("std");
const lib = @import("lib");

pub fn main() noreturn {
    const console = lib.syscall.fopen("/dev/console", .{ .access = .rw }) catch lib.syscall.exit(1);
    for (0..3) |i| {
        lib.syscall.fclone(console, @enumFromInt(i), .{ .close_on_exec = false }) catch {
            panic("failed to clone console fd\n");
        };
    }

    {
        lib.writeAll(lib.stdout, 0, "hello world\n") catch {};
        const fd = lib.syscall.fopen("/boot/grub/grub.cfg", .{}) catch {
            panic("failed to open file\n");
        };
        defer lib.syscall.fclose(fd) catch {};

        var buffer: [4096]u8 = undefined;
        const read = lib.syscall.fread(fd, 0, &buffer) catch {
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
