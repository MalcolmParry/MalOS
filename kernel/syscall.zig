const std = @import("std");
const arch = @import("arch/arch.zig").current;
const log = @import("log.zig");
const abi = @import("abi");
const vfs = @import("fs/vfs/vfs.zig");
const Task = @import("task/Task.zig");

const Handler = fn (args: [7]usize) Error!usize;
const Error = vfs.LookupError || vfs.OpenError || vfs.ReadError || vfs.WriteError || error{
    PathTooLong,
    Fault,
    TooManyFds,
    BadFd,
    BadArg,
};

fn errorToStatus(err: Error) abi.Status {
    return switch (err) {
        Error.Fault => .fault,
        Error.PathTooLong => .path_too_long,
        Error.TooManyFds => .too_many_fds,
        Error.Io => .io,
        Error.Corrupt => .corrupt,
        Error.OutOfMemory => .out_of_memory,
        Error.InvalidName => .invalid_name,
        Error.NotADir => .not_a_dir,
        Error.IsADir => .is_a_dir,
        Error.NameTooLong => .name_too_long,
        Error.NoEntry => .no_entry,
        Error.ReadOnly => .read_only,
        Error.NotSupported => .not_supported,
        Error.BadFd => .bad_fd,
        Error.BadArg => .bad_arg,
        Error.BadAccess => .bad_access,
    };
}

pub fn handler(args: [7]usize) [2]usize {
    const code = std.enums.fromInt(abi.Syscall, args[0]) orelse return .{ @intFromEnum(abi.Status.bad_syscall), 0 };

    const inner_handler: *const Handler = switch (code) {
        .fopen => &fopen,
        .fclose => &fclose,
        .fread => &fread,
        .fwrite => &fwrite,
        .fclone => &fclone,
    };

    const result = inner_handler(args) catch |err| {
        return .{ @intFromEnum(errorToStatus(err)), 0 };
    };

    return .{ @intFromEnum(abi.Status.success), result };
}

fn fopen(args: [7]usize) !usize {
    const flags: abi.FOpenFlags = try .fromUsize(args[3]);
    const len = args[2];
    const user_path = @as([*]allowzero const u8, @ptrFromInt(args[1]))[0..len];
    var path_buffer: [vfs.max_path_len]u8 = undefined;

    if (len > vfs.max_path_len) return error.PathTooLong;
    const path = path_buffer[0..len];
    if (!arch.copyFromUser(path, user_path)) return error.Fault;

    arch.interrupt.enable();
    defer arch.interrupt.disable();

    // TODO: add cwd
    const vfs_root = vfs.root.?.acquireRootPath();
    defer vfs_root.release();

    const vfs_path = try vfs_root.lookup(path);
    defer vfs_path.release();

    const task = Task.current_tid.get();
    const fd_table = task.fd_table orelse return error.TooManyFds;
    const file = try vfs_path.open(.{ .r = flags.access.r, .w = flags.access.w, .x = flags.access.x });
    const fd = try fd_table.putFd(.{
        .file = file,
        .flags = .{ .close_on_exec = flags.close_on_exec },
    });

    return @intFromEnum(fd);
}

fn fclose(args: [7]usize) !usize {
    const fd: abi.Fd = try .fromUsize(args[1]);

    const task = Task.current_tid.get();
    const fd_table = task.fd_table orelse return error.BadFd;
    if (!fd_table.removeFd(fd)) return error.BadFd;
    return 0;
}

fn fread(args: [7]usize) !usize {
    const fd: abi.Fd = try .fromUsize(args[1]);

    const offset = args[2];
    var full_buffer: [1024 * 4]u8 = undefined;
    const len = @min(args[4], full_buffer.len);
    const user_buffer = @as([*]allowzero u8, @ptrFromInt(args[3]))[0..len];
    const buffer = full_buffer[0..len];

    const task = Task.current_tid.get();
    const fd_table = task.fd_table orelse return error.BadFd;
    const desc = fd_table.getFd(fd) orelse return error.BadFd;
    defer desc.file.release();

    const read = blk: {
        arch.interrupt.enable();
        defer arch.interrupt.disable();
        break :blk try desc.file.read(offset, buffer, .{});
    };

    if (!arch.copyToUser(user_buffer[0..read], buffer[0..read])) return error.Fault;

    return read;
}

fn fwrite(args: [7]usize) !usize {
    const fd: abi.Fd = try .fromUsize(args[1]);

    const offset = args[2];
    var full_buffer: [1024 * 4]u8 = undefined;
    const len = @min(args[4], full_buffer.len);
    const user_buffer = @as([*]allowzero const u8, @ptrFromInt(args[3]))[0..len];
    const buffer = full_buffer[0..len];
    if (!arch.copyFromUser(buffer, user_buffer)) return error.Fault;

    const task = Task.current_tid.get();
    const fd_table = task.fd_table orelse return error.BadFd;
    const desc = fd_table.getFd(fd) orelse return error.BadFd;
    defer desc.file.release();

    arch.interrupt.enable();
    defer arch.interrupt.disable();
    return desc.file.write(offset, buffer, .{});
}

fn fclone(args: [7]usize) !usize {
    const old_fd: abi.Fd = try .fromUsize(args[1]);
    const new_fd: abi.Fd = try .fromUsize(args[2]);
    const flags: abi.FCloneFlags = try .fromUsize(args[3]);

    const task = Task.current_tid.get();
    const fd_table = task.fd_table orelse return error.BadFd;
    const old_desc = fd_table.getFd(old_fd) orelse return error.BadFd;
    const new_desc: Task.FileDesc = .{
        .file = old_desc.file,
        .flags = .{ .close_on_exec = flags.close_on_exec },
    };

    try fd_table.placeFd(new_fd, new_desc);
    return 0;
}
