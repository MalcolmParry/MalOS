const std = @import("std");
const arch = @import("arch/arch.zig").current;
const log = @import("log.zig");
const abi = @import("abi");
const vfs = @import("fs/vfs/vfs.zig");
const Task = @import("task/Task.zig");
const scheduler = @import("task/scheduler.zig");

const Handler = fn (args: [7]usize) Error![3]usize;
const Error = vfs.LookupError || vfs.OpenError || vfs.ReadError || vfs.WriteError || error{
    PathTooLong,
    Fault,
    TooManyHandles,
    BadHandle,
    BadArg,
    BadHandleKind,
};

fn errorToStatus(err: Error) abi.Status {
    return switch (err) {
        Error.Fault => .fault,
        Error.PathTooLong => .path_too_long,
        Error.TooManyHandles => .too_many_handles,
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
        Error.BadHandle => .bad_handle,
        Error.BadHandleKind => .bad_handle_kind,
        Error.BadArg => .bad_arg,
        Error.BadAccess => .bad_access,
    };
}

pub fn handler(args: [7]usize) [4]usize {
    const code = std.enums.fromInt(abi.Syscall, args[0]) orelse return .{ @intFromEnum(abi.Status.bad_syscall), 0, 0, 0 };

    const inner_handler: *const Handler = switch (code) {
        .handle_close => &handleClose,
        .handle_clone => &handleClone,

        .fopen => &fopen,
        .fread => &fread,
        .fwrite => &fwrite,
        .exit => &exit,
    };

    const result = inner_handler(args) catch |err| {
        return .{ @intFromEnum(errorToStatus(err)), 0, 0, 0 };
    };

    return [1]usize{@intFromEnum(abi.Status.success)} ++ result;
}

fn handleClose(args: [7]usize) ![3]usize {
    const handle: abi.Handle = try .fromUsize(args[1]);

    const task = Task.current_tid.get();
    const table = task.handle_table orelse return error.BadHandle;
    if (!table.remove(handle)) return error.BadHandle;
    return @splat(0);
}

fn handleClone(args: [7]usize) ![3]usize {
    const old: abi.Handle = try .fromUsize(args[1]);
    const new: abi.Handle = try .fromUsize(args[2]);

    const task = Task.current_tid.get();
    const table = task.handle_table orelse return error.BadHandle;
    const old_desc = table.get(old) orelse return error.BadHandle;

    try table.place(new, old_desc);
    return @splat(0);
}

fn fopen(args: [7]usize) ![3]usize {
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
    const table = task.handle_table orelse return error.TooManyHandles;
    const file = try vfs_path.open(.{ .r = flags.access.r, .w = flags.access.w, .x = flags.access.x });
    const handle = try table.put(.{ .file = file });

    return .{ @intFromEnum(handle), 0, 0 };
}

fn fread(args: [7]usize) ![3]usize {
    const handle: abi.Handle = try .fromUsize(args[1]);

    const offset = args[2];
    var full_buffer: [1024 * 4]u8 = undefined;
    const len = @min(args[4], full_buffer.len);
    const user_buffer = @as([*]allowzero u8, @ptrFromInt(args[3]))[0..len];
    const buffer = full_buffer[0..len];

    const task = Task.current_tid.get();
    const table = task.handle_table orelse return error.BadHandle;
    const desc = table.get(handle) orelse return error.BadHandle;
    defer desc.release();
    if (desc != .file) return error.BadHandleKind;

    const read = blk: {
        arch.interrupt.enable();
        defer arch.interrupt.disable();
        break :blk try desc.file.read(offset, buffer, .{});
    };

    if (!arch.copyToUser(user_buffer[0..read], buffer[0..read])) return error.Fault;

    return .{ read, 0, 0 };
}

fn fwrite(args: [7]usize) ![3]usize {
    const handle: abi.Handle = try .fromUsize(args[1]);

    const offset = args[2];
    var full_buffer: [1024 * 4]u8 = undefined;
    const len = @min(args[4], full_buffer.len);
    const user_buffer = @as([*]allowzero const u8, @ptrFromInt(args[3]))[0..len];
    const buffer = full_buffer[0..len];
    if (!arch.copyFromUser(buffer, user_buffer)) return error.Fault;

    const task = Task.current_tid.get();
    const table = task.handle_table orelse return error.BadHandle;
    const desc = table.get(handle) orelse return error.BadHandle;
    defer desc.release();
    if (desc != .file) return error.BadHandleKind;

    arch.interrupt.enable();
    defer arch.interrupt.disable();
    const wrote = try desc.file.write(offset, buffer, .{});
    return .{ wrote, 0, 0 };
}

fn exit(args: [7]usize) ![3]usize {
    const status = args[1];
    _ = status;

    scheduler.exitTask();
}
