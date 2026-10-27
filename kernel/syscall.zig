const std = @import("std");
const arch = @import("arch/arch.zig").current;
const log = @import("log.zig");
const abi = @import("abi");
const vfs = @import("fs/vfs/vfs.zig");
const gpa = @import("heap/gpa.zig").allocator;
const Task = @import("task/Task.zig");
const Object = @import("object/Object.zig");
const Channel = @import("object/Channel.zig");
const Socket = @import("object/Socket.zig");
const scheduler = @import("task/scheduler.zig");

const Handler = fn (args: [7]usize) Error![3]usize;
const Error = error{
    OutOfMemory,
    Fault,
    TooManyHandles,
    BadHandle,
    BadArg,
    BadHandleKind,
    TooBig,
    PeerClosed,
    IsFull,
    IsEmpty,
};

fn errorToStatus(err: Error) abi.Status {
    return switch (err) {
        Error.Fault => .fault,
        Error.TooManyHandles => .too_many_handles,
        Error.OutOfMemory => .out_of_memory,
        Error.BadHandle => .bad_handle,
        Error.BadHandleKind => .bad_handle_kind,
        Error.BadArg => .bad_arg,
        Error.TooBig => .too_big,
        Error.PeerClosed => .peer_closed,
        Error.IsFull => .is_full,
        Error.IsEmpty => .is_empty,
    };
}

pub fn handler(args: [7]usize) [4]usize {
    const code = std.enums.fromInt(abi.Syscall, args[0]) orelse return .{ @intFromEnum(abi.Status.bad_syscall), 0, 0, 0 };

    const inner_handler: *const Handler = switch (code) {
        .handle_close => &handleClose,
        .handle_clone => &handleClone,

        .channel_create_pair => &channelCreatePair,
        .channel_send => &channelSend,
        .channel_receive => &channelReceive,

        .socket_create_pair => &socketCreatePair,
        .socket_send => &socketSend,
        .socket_receive => &socketReceive,

        .klog_write => &klogWrite,

        .exit => &exit,
    };

    const result = inner_handler(args) catch |err| {
        return .{ @intFromEnum(errorToStatus(err)), 0, 0, 0 };
    };

    return [1]usize{@intFromEnum(abi.Status.success)} ++ result;
}

fn getObj(handle_usize: usize) !*Object {
    const h: abi.Handle = try .fromUsize(handle_usize);
    const task = Task.current_tid.get();
    const table = task.handle_table orelse return error.BadHandle;
    const desc = table.get(h) orelse return error.BadHandle;
    return desc.obj;
}

fn handleClose(args: [7]usize) abi.HandleCloseError![3]usize {
    const handle: abi.Handle = try .fromUsize(args[1]);

    const task = Task.current_tid.get();
    const table = task.handle_table orelse return error.BadHandle;
    if (!table.remove(handle)) return error.BadHandle;
    return @splat(0);
}

fn handleClone(args: [7]usize) abi.HandleCloneError![3]usize {
    const old: abi.Handle = try .fromUsize(args[1]);
    const new: abi.Handle = try .fromUsize(args[2]);

    const task = Task.current_tid.get();
    const table = task.handle_table orelse return error.BadHandle;
    const old_desc = table.get(old) orelse return error.BadHandle;

    try table.place(new, old_desc);
    return @splat(0);
}

fn socketCreatePair(_: [7]usize) abi.SocketCreatePairError![3]usize {
    const task = Task.current_tid.get();
    const table = task.handle_table orelse return error.TooManyHandles;

    const pair = try Socket.Pair.create();
    const d0: Task.HandleDesc = .{ .obj = &pair.end0.obj };
    const d1: Task.HandleDesc = .{ .obj = &pair.end1.obj };

    const h0 = table.put(d0) catch |err| {
        d1.obj.release();
        return err;
    };

    const h1 = table.put(d1) catch |err| {
        _ = table.remove(h0);
        return err;
    };

    return .{ @intFromEnum(h0), @intFromEnum(h1), 0 };
}

fn socketSend(args: [7]usize) abi.SocketSendError![3]usize {
    const obj = try getObj(args[1]);
    defer obj.release();
    const sock = obj.getSocket() orelse return error.BadHandleKind;

    var buffer: [1024 * 4]u8 = undefined;
    const len = @min(buffer.len, args[3]);
    const user_data = @as([*]allowzero const u8, @ptrFromInt(args[2]))[0..len];
    const data = buffer[0..len];
    if (!arch.copyFromUser(data, user_data)) return error.Fault;

    const sent = try sock.send(data);
    return .{ sent, 0, 0 };
}

fn socketReceive(args: [7]usize) abi.SocketReceiveError![3]usize {
    const obj = try getObj(args[1]);
    defer obj.release();
    const sock = obj.getSocket() orelse return error.BadHandleKind;

    var full_buffer: [1024 * 4]u8 = undefined;
    const buffer = full_buffer[0..@min(args[3], full_buffer.len)];

    const read = try sock.receive(buffer);
    const user_buffer = @as([*]allowzero u8, @ptrFromInt(args[2]))[0..read];
    // TODO: dont consume bytes on fault
    if (!arch.copyToUser(user_buffer, buffer[0..read])) return error.Fault;
    return .{ read, 0, 0 };
}

fn channelCreatePair(_: [7]usize) abi.ChannelCreatePairError![3]usize {
    const task = Task.current_tid.get();
    const table = task.handle_table orelse return error.TooManyHandles;

    const pair = try Channel.Pair.create();
    const d0: Task.HandleDesc = .{ .obj = &pair.end0.obj };
    const d1: Task.HandleDesc = .{ .obj = &pair.end1.obj };

    const h0 = table.put(d0) catch |err| {
        d1.obj.release();
        return err;
    };

    const h1 = table.put(d1) catch |err| {
        _ = table.remove(h0);
        return err;
    };

    return .{ @intFromEnum(h0), @intFromEnum(h1), 0 };
}

fn channelSend(args: [7]usize) abi.ChannelSendError![3]usize {
    const task = Task.current_tid.get();
    const table = task.handle_table orelse return error.BadHandle;
    const obj = try getObj(args[1]);
    defer obj.release();
    const channel = obj.getChannel() orelse return error.BadHandleKind;

    const byte_count = args[3];
    const handle_count = args[5];
    if (byte_count > Channel.max_bytes) return error.TooBig;
    if (handle_count > Channel.max_handles) return error.TooBig;

    const user_bytes = @as([*]allowzero const u8, @ptrFromInt(args[2]))[0..byte_count];
    const user_handles = @as([*]allowzero align(1) const abi.Handle, @ptrFromInt(args[4]))[0..handle_count];

    const msg = try gpa.create(Channel.Message);
    errdefer gpa.destroy(msg);

    const bytes = try gpa.alloc(u8, byte_count);
    errdefer gpa.free(bytes);

    var handle_buffer: [Channel.max_handles]abi.Handle = undefined;
    const handles = handle_buffer[0..handle_count];

    if (!arch.copyFromUser(bytes, user_bytes)) return error.Fault;
    if (!arch.copyFromUser(std.mem.sliceAsBytes(handles), std.mem.sliceAsBytes(user_handles))) return error.Fault;

    const descs = try gpa.alloc(Task.HandleDesc, handle_count);
    errdefer gpa.free(descs);

    var descs_loaded: usize = 0;
    errdefer for (descs[0..descs_loaded]) |d| d.obj.release();

    for (handles, descs) |h, *desc| {
        desc.* = table.get(h) orelse return error.BadHandle;
        descs_loaded += 1;

        if (desc.obj.getChannel()) |c| {
            if (c.getPair() == channel.getPair()) return error.BadArg;
        }
    }

    msg.* = .{
        .next = null,
        .destroy_ptr = &msgDestroy,
        .bytes = bytes,
        .handles = descs,
    };

    try channel.send(msg);
    return @splat(0);
}

fn msgDestroy(msg: *Channel.Message) void {
    gpa.free(msg.bytes);
    gpa.free(msg.handles);
    gpa.destroy(msg);
}

fn channelReceive(args: [7]usize) abi.ChannelReceiveError![3]usize {
    const task = Task.current_tid.get();
    const table = task.handle_table orelse return error.BadHandle;
    const obj = try getObj(args[1]);
    defer obj.release();
    const channel = obj.getChannel() orelse return error.BadHandleKind;

    var handle_buffer: [Channel.max_handles]abi.Handle = undefined;
    // TODO: block
    // TODO: return byte and handle count on error.TooBig
    // TODO: put the message back if there was an error
    const msg = try channel.receive(args[3], args[5]) orelse return @splat(0);
    defer msg.destroyNoReleaseHandles();
    const handles = handle_buffer[0..msg.handles.len];

    var handles_filled: usize = 0;
    errdefer {
        for (handles[0..handles_filled]) |h| _ = table.remove(h);
        for (msg.handles[handles_filled..]) |d| d.obj.release();
    }

    for (msg.handles, handles) |desc, *h| {
        h.* = try table.put(desc);
        handles_filled += 1;
    }

    const user_bytes = @as([*]allowzero u8, @ptrFromInt(args[2]))[0..msg.bytes.len];
    const user_handles = @as([*]allowzero align(1) abi.Handle, @ptrFromInt(args[4]))[0..msg.handles.len];

    if (!arch.copyToUser(user_bytes, msg.bytes)) return error.Fault;
    if (!arch.copyToUser(std.mem.sliceAsBytes(user_handles), std.mem.sliceAsBytes(handles))) return error.Fault;

    return .{ msg.bytes.len, msg.handles.len, 0 };
}

fn klogWrite(args: [7]usize) abi.KLogWriteError![3]usize {
    const obj = try getObj(args[1]);
    defer obj.release();
    if (obj.kind != .klog) return error.BadHandleKind;

    var buffer: [4096]u8 = undefined;
    const len = @min(buffer.len, args[3]);
    const user_data = @as([*]allowzero const u8, @ptrFromInt(args[2]))[0..len];
    const data = buffer[0..len];
    if (!arch.copyFromUser(data, user_data)) return error.Fault;

    log.writer.writeAll(data) catch {};

    return @splat(0);
}

fn exit(args: [7]usize) ![3]usize {
    const status = args[1];
    _ = status;

    scheduler.exitTask();
}
