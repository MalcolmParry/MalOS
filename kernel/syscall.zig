const std = @import("std");
const arch = @import("arch/arch.zig").current;
const log = @import("log.zig");
const abi = @import("abi");
const vfs = @import("fs/vfs/vfs.zig");
const Task = @import("task/Task.zig");

pub fn handler(args: [5]usize) [2]usize {
    const code = std.enums.fromInt(abi.Syscall, args[0]) orelse return .{ @intFromEnum(abi.Status.invalid_syscall), 0 };

    switch (code) {
        .debug_print => {
            const status = debugPrint(args);
            return .{ @intFromEnum(status), 0 };
        },
        .fopen => {
            const err_fd = fopen(args);
            const fd = err_fd catch |err| {
                const status: abi.Status = switch (err) {
                    else => .unknown,
                };

                return .{ @intFromEnum(status), 0 };
            };

            return .{ @intFromEnum(abi.Status.success), @intFromEnum(fd) };
        },
        .fread => {
            const err_read = fread(args);
            const read = err_read catch |err| {
                const status: abi.Status = switch (err) {
                    else => .unknown,
                };

                return .{ @intFromEnum(status), 0 };
            };

            return .{ @intFromEnum(abi.Status.success), read };
        },
    }
}

fn debugPrint(args: [5]usize) abi.Status {
    const len = args[2];
    const src = @as([*]allowzero const u8, @ptrFromInt(args[1]))[0..len];
    var buffer: [1024 * 4]u8 = undefined;

    if (len > buffer.len) return .too_long;

    const dst = buffer[0..len];
    if (!arch.copyFromUser(dst, src)) return .fault;

    const l = log.spinlock.lock();
    defer l.unlock();

    log.writer.writeAll(dst) catch return .unknown;
    log.writer.flush() catch {};

    return .success;
}

fn fopen(args: [5]usize) !abi.Fd {
    const len = args[2];
    const user_path = @as([*]allowzero const u8, @ptrFromInt(args[1]))[0..len];
    var path_buffer: [vfs.max_name_len]u8 = undefined;

    if (len > vfs.max_name_len) return error.NameTooLong;
    const path = path_buffer[0..len];
    if (!arch.copyFromUser(path, user_path)) return error.Fault;

    arch.interrupt.enable();
    defer arch.interrupt.disable();

    // TODO: add cwd
    const vfs_root = vfs.root.?.acquireRootPath();
    defer vfs_root.release();

    const vfs_path = try vfs_root.lookup(path);
    defer vfs_path.release();

    const file = try vfs_path.open();
    errdefer file.close();

    const task = Task.current_tid.get();
    const fd_table = task.fd_table orelse return error.TooManyFds;
    const fd = try fd_table.putFd(file);

    return fd;
}

fn fread(args: [5]usize) !usize {
    if (args[1] > abi.Fd.max) return error.BadFd;
    const fd: abi.Fd = @enumFromInt(args[1]);

    const offset = args[2];
    var full_buffer: [1024 * 4]u8 = undefined;
    const len = @min(args[4], full_buffer.len);
    const user_buffer = @as([*]allowzero u8, @ptrFromInt(args[3]))[0..len];
    const buffer = full_buffer[0..len];

    const task = Task.current_tid.get();
    const fd_table = task.fd_table orelse return error.BadFd;
    const file = fd_table.getFd(fd) orelse return error.BadFd;
    // TODO: defer release

    const read = blk: {
        arch.interrupt.enable();
        defer arch.interrupt.disable();
        break :blk try file.read(offset, buffer);
    };

    if (!arch.copyToUser(user_buffer[0..read], buffer[0..read])) return error.Fault;

    return read;
}
