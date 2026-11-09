const std = @import("std");
const mem = @import("memory.zig");
const arch = @import("arch/arch.zig").current;
const log = @import("log.zig");
const abi = @import("abi");
const gpa = @import("heap/gpa.zig").allocator;
const Object = @import("object/Object.zig");
const Channel = @import("object/Channel.zig");
const Socket = @import("object/Socket.zig");
const HandleTable = @import("proc/HandleTable.zig");
const Thread = @import("proc/Thread.zig");
const Vmo = @import("object/Vmo.zig");
const Vmar = @import("object/Vmar.zig");
const Process = @import("proc/Process.zig");
const PageAlloc = @import("heap/PageAllocator.zig");
const scheduler = @import("proc/scheduler.zig");

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
    NoRight,
    OutOfRange,
    NotAligned,
    NoGap,
    BadState,
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
        Error.NoRight => .no_right,
        Error.OutOfRange => .out_of_range,
        Error.NotAligned => .not_aligned,
        Error.NoGap => .no_gap,
        Error.BadState => .bad_state,
    };
}

pub fn handler(args: [7]usize) [4]usize {
    const code = std.enums.fromInt(abi.Syscall, args[0]) orelse return .{ @intFromEnum(abi.Status.bad_syscall), 0, 0, 0 };

    const inner_handler: *const Handler = switch (code) {
        .handle_close => &handleClose,
        .handle_duplicate => &handleDuplicate,

        .channel_create_pair => &channelCreatePair,
        .channel_send => &channelSend,
        .channel_receive => &channelReceive,

        .socket_create_pair => &socketCreatePair,
        .socket_send => &socketSend,
        .socket_receive => &socketReceive,

        .klog_write => &klogWrite,

        .vmo_create => &vmoCreate,
        .vmo_write => &vmoWrite,
        .vmo_read => &vmoRead,
        .vmo_get_size => &vmoGetSize,

        .vmar_map => &vmarMap,

        .process_create => &processCreate,
        .process_transfer_handles => &processTransferHandles,

        .thread_create => &threadCreate,
        .thread_start => &threadStart,
        .thread_exit => &threadExit,
    };

    const result = inner_handler(args) catch |err| {
        return .{ @intFromEnum(errorToStatus(err)), 0, 0, 0 };
    };

    return [1]usize{@intFromEnum(abi.Status.success)} ++ result;
}

fn getObj(handle_usize: usize, required_rights: abi.Rights) !*Object {
    const h: abi.Handle = try .fromUsize(handle_usize);
    const table = HandleTable.getCurrent();
    const l = table.lock.lock();
    defer l.unlock();

    const desc = table.getLocked(h) orelse return error.BadHandle;
    if (!desc.rights.hasAll(required_rights)) return error.NoRight;

    desc.obj.acquire();
    return desc.obj;
}

fn handleClose(args: [7]usize) abi.HandleCloseError![3]usize {
    const handle: abi.Handle = try .fromUsize(args[1]);

    const old = blk: {
        const table = HandleTable.getCurrent();
        const l = table.lock.lock();
        defer l.unlock();

        break :blk table.fetchRemoveLocked(handle) orelse return error.BadHandle;
    };

    old.obj.release();
    return @splat(0);
}

fn handleDuplicate(args: [7]usize) abi.HandleDuplicateError![3]usize {
    const old: abi.Handle = try .fromUsize(args[1]);
    const requested_rights: abi.Rights = try .fromUsize(args[2]);

    const table = HandleTable.getCurrent();
    const l = table.lock.lock();
    defer l.unlock();

    const old_desc = table.getLocked(old) orelse return error.BadHandle;
    if (!old_desc.rights.duplicate) return error.NoRight;
    const rights = if (requested_rights.same) old_desc.rights else requested_rights;
    if (!old_desc.rights.hasAll(rights)) return error.NoRight;

    const new = try table.putLocked(.{ .obj = old_desc.obj, .rights = rights });
    old_desc.obj.acquire();
    return .{ @intFromEnum(new), 0, 0 };
}

fn socketCreatePair(_: [7]usize) abi.SocketCreatePairError![3]usize {
    const rights: abi.Rights = .{
        .duplicate = true,
        .transfer = true,
        .read = true,
        .write = true,
    };

    const pair = try Socket.Pair.create();
    errdefer {
        pair.end0.obj.release();
        pair.end1.obj.release();
    }

    const d0: HandleTable.Desc = .{ .obj = &pair.end0.obj, .rights = rights };
    const d1: HandleTable.Desc = .{ .obj = &pair.end1.obj, .rights = rights };

    const table = HandleTable.getCurrent();
    const l = table.lock.lock();
    defer l.unlock();

    const h0 = try table.putLocked(d0);
    errdefer std.debug.assert(table.fetchRemoveLocked(h0) != null);
    const h1 = try table.putLocked(d1);

    return .{ @intFromEnum(h0), @intFromEnum(h1), 0 };
}

fn socketSend(args: [7]usize) abi.SocketSendError![3]usize {
    const obj = try getObj(args[1], .{ .write = true });
    defer obj.release();
    const sock = obj.get(Socket) orelse return error.BadHandleKind;

    var buffer: [1024 * 4]u8 = undefined;
    const len = @min(buffer.len, args[3]);
    const user_data = @as([*]allowzero const u8, @ptrFromInt(args[2]))[0..len];
    const data = buffer[0..len];
    if (!arch.copyFromUser(data, user_data)) return error.Fault;

    const sent = try sock.send(data);
    return .{ sent, 0, 0 };
}

fn socketReceive(args: [7]usize) abi.SocketReceiveError![3]usize {
    const obj = try getObj(args[1], .{ .read = true });
    defer obj.release();
    const sock = obj.get(Socket) orelse return error.BadHandleKind;

    var full_buffer: [1024 * 4]u8 = undefined;
    const buffer = full_buffer[0..@min(args[3], full_buffer.len)];

    const read = try sock.receive(buffer);
    const user_buffer = @as([*]allowzero u8, @ptrFromInt(args[2]))[0..read];
    // TODO: dont consume bytes on fault
    if (!arch.copyToUser(user_buffer, buffer[0..read])) return error.Fault;
    return .{ read, 0, 0 };
}

fn channelCreatePair(_: [7]usize) abi.ChannelCreatePairError![3]usize {
    const rights: abi.Rights = .{
        .transfer = true,
        .read = true,
        .write = true,
    };

    const pair = try Channel.Pair.create();
    errdefer {
        pair.end0.obj.release();
        pair.end1.obj.release();
    }

    const d0: HandleTable.Desc = .{ .obj = &pair.end0.obj, .rights = rights };
    const d1: HandleTable.Desc = .{ .obj = &pair.end1.obj, .rights = rights };

    const table = HandleTable.getCurrent();
    const l = table.lock.lock();
    defer l.unlock();

    const h0 = try table.putLocked(d0);
    errdefer std.debug.assert(table.fetchRemoveLocked(h0) != null);
    const h1 = try table.putLocked(d1);

    return .{ @intFromEnum(h0), @intFromEnum(h1), 0 };
}

fn channelSend(args: [7]usize) abi.ChannelSendError![3]usize {
    const obj = try getObj(args[1], .{ .write = true });
    defer obj.release();
    const channel = obj.get(Channel) orelse return error.BadHandleKind;

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

    const descs = try gpa.alloc(HandleTable.Desc, handle_count);
    errdefer gpa.free(descs);

    const table = HandleTable.getCurrent();
    const l = table.lock.lock();
    defer l.unlock();

    for (handles, descs, 0..) |h, *desc, i| {
        for (handles[0..i]) |prev| if (prev == h) return error.BadArg;
        desc.* = table.getLocked(h) orelse return error.BadHandle;

        if (!desc.rights.transfer) return error.NoRight;
        if (desc.obj.get(Channel)) |c| {
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
    for (handles) |h| std.debug.assert(table.fetchRemoveLocked(h) != null);
    return @splat(0);
}

fn msgDestroy(msg: *Channel.Message) void {
    gpa.free(msg.bytes);
    gpa.free(msg.handles);
    gpa.destroy(msg);
}

fn channelReceive(args: [7]usize) abi.ChannelReceiveError![3]usize {
    const obj = try getObj(args[1], .{ .read = true });
    defer obj.release();
    const channel = obj.get(Channel) orelse return error.BadHandleKind;

    var handle_buffer: [Channel.max_handles]abi.Handle = undefined;
    // TODO: return byte and handle count on error.TooBig
    // TODO: put the message back if there was an error
    const msg = try channel.receive(args[3], args[5]) orelse return @splat(0);
    defer msg.destroyNoReleaseHandles();
    const handles = handle_buffer[0..msg.handles.len];

    const table = HandleTable.getCurrent();
    {
        const l = table.lock.lock();
        defer l.unlock();

        var handles_filled: usize = 0;
        errdefer {
            for (handles[0..handles_filled]) |h| std.debug.assert(table.fetchRemoveLocked(h) != null);
            for (msg.handles) |d| d.obj.release();
        }

        for (msg.handles, handles) |desc, *h| {
            h.* = try table.putLocked(desc);
            handles_filled += 1;
        }
    }

    errdefer {
        const l = table.lock.lock();
        defer l.unlock();

        for (handles) |h| {
            const desc = table.fetchRemoveLocked(h) orelse continue;
            desc.obj.release();
        }
    }

    const user_bytes = @as([*]allowzero u8, @ptrFromInt(args[2]))[0..msg.bytes.len];
    const user_handles = @as([*]allowzero align(1) abi.Handle, @ptrFromInt(args[4]))[0..msg.handles.len];

    if (!arch.copyToUser(user_bytes, msg.bytes)) return error.Fault;
    if (!arch.copyToUser(std.mem.sliceAsBytes(user_handles), std.mem.sliceAsBytes(handles))) return error.Fault;

    return .{ msg.bytes.len, msg.handles.len, 0 };
}

fn klogWrite(args: [7]usize) abi.KLogWriteError![3]usize {
    const obj = try getObj(args[1], .{ .write = true });
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

fn vmoCreate(args: [7]usize) abi.VmoCreateError![3]usize {
    const size = args[1];
    const vmo = try Vmo.create(size);

    const table = HandleTable.getCurrent();
    const l = table.lock.lock();
    defer l.unlock();

    const h = try table.putLocked(.{
        .obj = &vmo.obj,
        .rights = .{
            .duplicate = true,
            .transfer = true,
            .read = true,
            .write = true,
            .exec = true,
        },
    });

    return .{ @intFromEnum(h), 0, 0 };
}

fn vmoWrite(args: [7]usize) abi.VmoWriteError![3]usize {
    const obj = try getObj(args[1], .{ .write = true });
    defer obj.release();
    const vmo = obj.get(Vmo) orelse return error.BadHandleKind;

    var vmo_offset = args[2];
    var remaining_user = @as([*]allowzero const u8, @ptrFromInt(args[3]))[0..args[4]];
    while (remaining_user.len != 0) {
        var buffer: [8 * 1024]u8 = undefined;
        const user = remaining_user[0..@min(remaining_user.len, buffer.len)];
        const data = buffer[0..user.len];
        if (!arch.copyFromUser(data, user)) return error.Fault;

        try vmo.write(vmo_offset, data);
        remaining_user = remaining_user[data.len..];
        vmo_offset += data.len;
    }

    return @splat(0);
}

fn vmoRead(args: [7]usize) abi.VmoReadError![3]usize {
    const obj = try getObj(args[1], .{ .read = true });
    defer obj.release();
    const vmo = obj.get(Vmo) orelse return error.BadHandleKind;

    var vmo_offset = args[2];
    var remaining_user = @as([*]allowzero u8, @ptrFromInt(args[3]))[0..args[4]];
    while (remaining_user.len != 0) {
        var full_buffer: [8 * 1024]u8 = undefined;
        const user = remaining_user[0..@min(remaining_user.len, full_buffer.len)];
        const buffer = full_buffer[0..user.len];

        try vmo.read(vmo_offset, buffer);
        remaining_user = remaining_user[buffer.len..];
        vmo_offset += buffer.len;

        if (!arch.copyToUser(user, buffer)) return error.Fault;
    }

    return @splat(0);
}

fn vmoGetSize(args: [7]usize) abi.VmoGetSizeError![3]usize {
    const obj = getObj(args[1], .{}) catch |err| return switch (err) {
        error.NoRight => unreachable,
        else => |x| x,
    };
    defer obj.release();
    const vmo = obj.get(Vmo) orelse return error.BadHandleKind;
    const l = vmo.lock.lock();
    defer l.unlock();
    return .{ vmo.size, 0, 0 };
}

fn vmarMap(args: [7]usize) abi.VmarMapError![3]usize {
    const requested_vmar_offset = args[2];
    const vmo_offset = args[4];
    const len = args[5];
    const opts: abi.VmarMapOpts = try .fromUsize(args[6]);

    if (len == 0) return error.BadArg;
    if (opts.placement == .normal and requested_vmar_offset != 0) return error.BadArg;
    if (requested_vmar_offset % mem.page_size != 0) return error.NotAligned;
    if (vmo_offset % mem.page_size != 0) return error.NotAligned;

    const vmo_end = std.math.add(usize, vmo_offset, len) catch return error.OutOfRange;
    if (vmo_end >= std.math.maxInt(usize) - mem.page_size) return error.OutOfRange;
    const vmo_page_offset = (vmo_offset + mem.page_size - 1) / mem.page_size;
    const page_count = (len + mem.page_size - 1) / mem.page_size;

    const rights: abi.Rights = switch (opts.perm) {
        .ro => .{ .read = true },
        .rw => .{ .read = true, .write = true },
        .rx => .{ .read = true, .exec = true },
        _ => unreachable,
    };

    const vmar_obj = try getObj(args[1], rights);
    defer vmar_obj.release();
    const vmar = vmar_obj.get(Vmar) orelse return error.BadHandleKind;

    const vmo_obj = try getObj(args[3], rights);
    defer vmo_obj.release();
    const vmo = vmo_obj.get(Vmo) orelse return error.BadHandleKind;

    const vmar_l = vmar.lock.lock();
    defer vmar_l.unlock();
    const vmo_l = vmo.lock.lock();
    defer vmo_l.unlock();

    const vmar_page_offset = blk: switch (opts.placement) {
        .normal => vmar.findGapLocked(page_count, null) orelse return error.NoGap,
        .fixed, .fixed_overwrite => {
            const vmar_end = std.math.add(usize, requested_vmar_offset, len) catch return error.BadArg;
            if (vmar_end > arch.paging.max_user_addr) return error.BadArg;
            const requested_vmar_page_offset = @divExact(requested_vmar_offset, mem.page_size);

            // TODO: check for overwrite

            break :blk requested_vmar_page_offset;
        },
        _ => unreachable,
    };

    if (rights.write) try vmo.commitLocked(vmo_page_offset, page_count);
    try vmar.mapLocked(vmo, vmo_page_offset, vmar_page_offset, page_count, .{
        .w = rights.write,
        .x = rights.exec,
    });

    return .{ vmar_page_offset * mem.page_size, 0, 0 };
}

fn processCreate(_: [7]usize) abi.ProcessCreateError![3]usize {
    const handle_table = HandleTable.getCurrent();
    const proc = try Process.create();
    const l = handle_table.lock.lock();
    defer l.unlock();

    const proc_h = try handle_table.putLocked(.{
        .obj = &proc.obj,
        .rights = .{
            .duplicate = true,
            .transfer = true,
            .transfer_to = true,
        },
    });
    errdefer handle_table.fetchRemoveLocked(proc_h).?.obj.release();

    proc.vmar.obj.acquire();
    const vmar_h = try handle_table.putLocked(.{
        .obj = &proc.vmar.obj,
        .rights = .{
            .duplicate = true,
            .transfer = true,
            .read = true,
            .write = true,
            .exec = true,
        },
    });

    return .{ @intFromEnum(proc_h), @intFromEnum(vmar_h), 0 };
}

fn processTransferHandles(args: [7]usize) abi.ProcessTransferHandlesError![3]usize {
    const proc = Thread.current.proc.?;
    const other_obj = try getObj(args[1], .{ .transfer_to = true });
    defer other_obj.release();
    const other = other_obj.get(Process) orelse return error.BadHandleKind;

    const transfer_count = args[4];
    if (transfer_count > abi.max_process_handle_transfers) return error.TooBig;
    const user_handle_transfers = @as([*]allowzero align(1) const abi.HandleTransfer, @ptrFromInt(args[2]))[0..transfer_count];
    var handle_transfer_buffer: [abi.max_process_handle_transfers]abi.HandleTransfer = undefined;
    const handle_transfers = handle_transfer_buffer[0..transfer_count];
    if (!arch.copyFromUser(std.mem.sliceAsBytes(handle_transfers), std.mem.sliceAsBytes(user_handle_transfers))) return error.Fault;

    for (handle_transfers) |transfer| if (!transfer.isValid()) return error.BadArg;

    var desc_buffer: [abi.max_process_handle_transfers]HandleTable.Desc = undefined;
    const descs = desc_buffer[0..transfer_count];

    {
        const handle_table = &proc.handle_table;
        const l = handle_table.lock.lock();
        defer l.unlock();

        for (handle_transfers, descs, 0..) |transfer, *desc, i| {
            desc.* = proc.handle_table.getLocked(transfer.handle) orelse return error.BadHandle;
            for (0..i) |k| if (transfer.handle == handle_transfers[k].handle) return error.BadArg;

            if (!desc.rights.transfer or (transfer.op == .duplicate and !desc.rights.duplicate)) return error.NoRight;
            if (!transfer.rights.same) {
                if (!desc.rights.hasAll(transfer.rights)) return error.NoRight;
                desc.rights = transfer.rights;
            }
        }

        for (handle_transfers, descs) |transfer, desc| {
            switch (transfer.op) {
                .transfer => _ = handle_table.fetchRemoveLocked(transfer.handle).?,
                .duplicate => desc.obj.acquire(),
                _ => unreachable,
            }
        }
    }

    const user_out_handles = @as([*]allowzero align(1) abi.Handle, @ptrFromInt(args[3]))[0..transfer_count];
    var out_handle_buffer: [abi.max_process_handle_transfers]abi.Handle = undefined;
    const out_handles = out_handle_buffer[0..transfer_count];

    {
        errdefer for (descs) |desc| desc.obj.release();

        const handle_table = &other.handle_table;
        const l = other.lock.lock();
        defer l.unlock();
        if (other.state == .dead) return error.BadState;
        _ = handle_table.lock.lock();
        defer handle_table.lock.unlockNoPreserveInt();

        var filled: usize = 0;
        errdefer for (out_handles[0..filled]) |x| {
            _ = handle_table.fetchRemoveLocked(x).?;
        };

        for (descs, out_handles) |desc, *out| {
            out.* = try handle_table.putLocked(desc);
            filled += 1;
        }
    }

    if (!arch.copyToUser(std.mem.sliceAsBytes(user_out_handles), std.mem.sliceAsBytes(out_handles))) return error.Fault;
    return @splat(0);
}

fn threadCreate(args: [7]usize) abi.ThreadCreateError![3]usize {
    const handle_table = HandleTable.getCurrent();
    // TODO: add right for this
    const proc_obj = getObj(args[1], .{}) catch |err| return switch (err) {
        error.NoRight => unreachable,
        else => |x| x,
    };
    defer proc_obj.release();
    const proc = proc_obj.get(Process) orelse return error.BadHandleKind;

    const stack_size = 32 * 1024;
    const kernel_stack = PageAlloc.global.alloc(stack_size / mem.page_size, .{
        .global = true,
        .cache_mode = .full,
        .executable = false,
        .user = false,
        .writable = true,
    }) catch return error.OutOfMemory;

    const thread = Thread.create(proc, kernel_stack) catch |err| {
        PageAlloc.global.free(kernel_stack);
        return err;
    };

    const l = handle_table.lock.lock();
    defer l.unlock();

    const h = try handle_table.putLocked(.{
        .obj = &thread.obj,
        // TODO: add rights
        .rights = .{
            .duplicate = true,
            .transfer = true,
        },
    });

    return .{ @intFromEnum(h), 0, 0 };
}

fn threadStart(args: [7]usize) abi.ThreadStartError![3]usize {
    var info: abi.ThreadStartInfo = undefined;
    if (!arch.copyFromUser(std.mem.asBytes(&info), @as([*]allowzero const u8, @ptrFromInt(args[2]))[0..@sizeOf(abi.ThreadStartInfo)])) return error.Fault;

    if (info.ip >= arch.paging.max_user_addr) return error.BadArg;

    const state = arch.cpu.getUserThreadFrame(.{
        .entry = info.ip,
        .sp = info.sp,
        .args = info.args,
    });

    // TODO: add right for this
    const thread_obj = getObj(args[1], .{}) catch |err| return switch (err) {
        error.NoRight => unreachable,
        else => |x| x,
    };
    defer thread_obj.release();
    const thread = thread_obj.get(Thread) orelse return error.BadHandleKind;

    try thread.start(&state);
    return @splat(0);
}

fn threadExit(_: [7]usize) ![3]usize {
    Thread.exitCurrent();
}
