const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi");

pub fn handleClose(handle: abi.Handle) !void {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.handle_close),
        @intFromEnum(handle),
    });

    return switch (try readStatus(result[0])) {
        .success => {},
        .bad_handle => error.BadHandle,
        else => unexpected(result[0]),
    };
}

pub fn handleClone(old: abi.Handle, new: abi.Handle) !void {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.handle_clone),
        @intFromEnum(old),
        @intFromEnum(new),
    });

    return switch (try readStatus(result[0])) {
        .success => {},
        .bad_handle => error.BadHandle,
        .out_of_memory => error.OutOfMemory,
        else => unexpected(result[0]),
    };
}

pub fn channelCreatePair() !struct { abi.Handle, abi.Handle } {
    const result = syscall(.{@intFromEnum(abi.Syscall.channel_create_pair)});

    return switch (try readStatus(result[0])) {
        .success => .{
            @enumFromInt(result[1]),
            @enumFromInt(result[2]),
        },
        .out_of_memory => error.OutOfMemory,
        .too_many_handles => error.TooManyHandles,
        else => unexpected(result[0]),
    };
}

pub fn channelSend(channel: abi.Handle, bytes: []const u8, handles: []const abi.Handle) !void {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.channel_send),
        @intFromEnum(channel),
        @intFromPtr(bytes.ptr),
        bytes.len,
        @intFromPtr(handles.ptr),
        handles.len,
    });

    return switch (try readStatus(result[0])) {
        .success => {},
        .out_of_memory => error.OutOfMemory,
        .bad_handle => error.BadHandle,
        .bad_handle_kind => error.BadHandleKind,
        .too_big => error.TooBig,
        .peer_closed => error.PeerClosed,
        .fault => error.Fault,
        else => unexpected(result[0]),
    };
}

pub fn channelReceive(channel: abi.Handle, bytes: []u8, handles: []abi.Handle) !struct { usize, usize } {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.channel_receive),
        @intFromEnum(channel),
        @intFromPtr(bytes.ptr),
        bytes.len,
        @intFromPtr(handles.ptr),
        handles.len,
    });

    return switch (try readStatus(result[0])) {
        .success => .{ result[1], result[2] },
        .bad_handle => error.BadHandle,
        .bad_handle_kind => error.BadHandleKind,
        .too_big => error.TooBig,
        .too_many_handles => error.TooManyHandles,
        .out_of_memory => error.OutOfMemory,
        .fault => error.Fault,
        else => unexpected(result[0]),
    };
}

pub fn socketCreatePair() !struct { abi.Handle, abi.Handle } {
    const result = syscall(.{@intFromEnum(abi.Syscall.socket_create_pair)});

    return switch (try readStatus(result[0])) {
        .success => .{
            @enumFromInt(result[1]),
            @enumFromInt(result[2]),
        },
        .out_of_memory => error.OutOfMemory,
        .too_many_handles => error.TooManyHandles,
        else => unexpected(result[0]),
    };
}

pub fn socketSend(sock: abi.Handle, data: []const u8) !usize {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.socket_send),
        @intFromEnum(sock),
        @intFromPtr(data.ptr),
        data.len,
    });

    return switch (try readStatus(result[0])) {
        .success => result[1],
        .is_full => error.IsFull,
        .fault => error.Fault,
        .bad_handle => error.BadHandle,
        .bad_handle_kind => error.BadHandleKind,
        .peer_closed => error.PeerClosed,
        else => unexpected(result[0]),
    };
}

pub fn socketReceive(sock: abi.Handle, buffer: []u8) !usize {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.socket_receive),
        @intFromEnum(sock),
        @intFromPtr(buffer.ptr),
        buffer.len,
    });

    return switch (try readStatus(result[0])) {
        .success => result[1],
        .is_empty => error.IsEmpty,
        .fault => error.Fault,
        .bad_handle => error.BadHandle,
        .bad_handle_kind => error.BadHandleKind,
        .peer_closed => error.PeerClosed,
        else => unexpected(result[0]),
    };
}

pub fn klogWrite(klog: abi.Handle, data: []allowzero const u8) !void {
    const result = syscall(.{
        @intFromEnum(abi.Syscall.klog_write),
        @intFromEnum(klog),
        @intFromPtr(data.ptr),
        data.len,
    });

    return switch (try readStatus(result[0])) {
        .success => {},
        .fault => error.Fault,
        .bad_handle => error.BadHandle,
        .bad_handle_kind => error.BadHandleKind,
        else => unexpected(result[0]),
    };
}
pub fn exit(status: usize) noreturn {
    _ = syscall(.{
        @intFromEnum(abi.Syscall.exit),
        status,
    });

    @panic("exit syscall returned");
}

fn readStatus(int: usize) error{Unexpected}!abi.Status {
    return std.enums.fromInt(abi.Status, int) orelse unexpected(int);
}

fn unexpected(status: usize) error{Unexpected} {
    if (builtin.mode == .Debug) {
        // TODO: print warning
    }

    _ = status;
    return error.Unexpected;
}

pub fn syscall(args: anytype) [4]usize {
    const args7 = args ++ @as([7 - args.len]usize, @splat(0));
    return syscall7(args7);
}

pub fn syscall7(args: [7]usize) [4]usize {
    var ret0: usize = undefined;
    var ret1: usize = undefined;
    var ret2: usize = undefined;
    var ret3: usize = undefined;

    asm volatile (
        \\ int $0x80
        : [ret0] "={rax}" (ret0),
          [ret1] "={rdi}" (ret1),
          [ret2] "={rsi}" (ret2),
          [ret3] "={rdx}" (ret3),
        : [arg0] "{rax}" (args[0]),
          [arg1] "{rdi}" (args[1]),
          [arg2] "{rsi}" (args[2]),
          [arg3] "{rdx}" (args[3]),
          [arg4] "{r10}" (args[4]),
          [arg5] "{r8}" (args[5]),
          [arg6] "{r9}" (args[6]),
        : .{ .memory = true });

    return .{ ret0, ret1, ret2, ret3 };
}
