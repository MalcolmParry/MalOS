const std = @import("std");

pub const max_channel_msg_bytes = 16 * 1024;
pub const max_channel_msg_handles = 16;
pub const max_klog_msg = 4 * 1024;
pub const max_klog_entry = max_klog_msg + @sizeOf(KLogEntry);
pub const max_klog_scope = 8;
pub const max_process_handle_transfers = 64;

pub const Syscall = enum(usize) {
    handle_close,
    handle_duplicate,

    channel_create_pair,
    channel_send,
    channel_receive,

    socket_create_pair,
    socket_send,
    socket_receive,

    klog_write,
    klog_read,
    klog_disable_backend,

    vmo_create,
    vmo_write,
    vmo_read,
    vmo_get_size,

    vmar_map,

    process_create,
    process_transfer_handles,

    thread_create,
    thread_start,
    thread_exit,

    sleep_ns,

    resource_clone,

    x86_ioports_acquire,
};

pub const Status = enum(usize) {
    success,

    bad_syscall,
    bad_arg,
    fault,
    too_many_handles,
    out_of_memory,
    bad_handle,
    bad_handle_kind,
    peer_closed,
    too_big,
    is_full,
    is_empty,
    no_right,
    out_of_range,
    not_aligned,
    no_gap,
    bad_state,
};

pub const Handle = enum(u32) {
    invalid = 0,
    _,

    pub const max = std.math.maxInt(u32);
    pub fn fromUsize(int: usize) !Handle {
        if (int > max) return error.BadHandle;
        return .fromUsizeUnsafe(int);
    }

    pub fn fromUsizeUnsafe(int: usize) Handle {
        return @fromBackingInt(@intCast(int));
    }
};

pub const Rights = packed struct(u32) {
    duplicate: bool = false,
    transfer: bool = false,
    read: bool = false,
    write: bool = false,
    exec: bool = false,
    transfer_to: bool = false,

    unused: u25 = 0,
    same: bool = false,

    pub const ro: Rights = .{ .read = true };
    pub const rw: Rights = .{ .read = true, .write = true };
    pub const rx: Rights = .{ .read = true, .exec = true };
    pub const rwx: Rights = .{ .read = true, .write = true, .exec = true };
    pub const wo: Rights = .{ .write = true };

    pub const basic: Rights = .{ .duplicate = true, .transfer = true };
    pub const basic_ro = basic.merge(ro);
    pub const basic_rw = basic.merge(rw);
    pub const basic_rx = basic.merge(rx);
    pub const basic_rwx = basic.merge(rwx);
    pub const basic_wo = basic.merge(wo);

    const Backing = u32;
    pub fn fromUsize(int: usize) !Rights {
        if (int > std.math.maxInt(Backing)) return error.BadArg;
        const rights: Rights = @bitCast(@as(Backing, @intCast(int)));
        if (!rights.isValid()) return error.BadArg;
        return rights;
    }

    pub fn toUsize(rights: Rights) usize {
        return @as(Backing, @bitCast(rights));
    }

    pub fn isValid(rights: Rights) bool {
        if (rights.unused != 0) return false;
        if (rights.same and rights != Rights{ .same = true }) return false;
        return true;
    }

    pub fn intersect(left: Rights, right: Rights) Rights {
        return @bitCast(@as(Backing, @bitCast(left)) & @as(Backing, @bitCast(right)));
    }

    pub fn merge(left: Rights, right: Rights) Rights {
        return @bitCast(@as(Backing, @bitCast(left)) | @as(Backing, @bitCast(right)));
    }

    pub fn hasAll(left: Rights, right: Rights) bool {
        return left.intersect(right) == right;
    }
};

pub const HandleTransfer = extern struct {
    op: Op,
    handle: Handle,
    rights: Rights,

    pub const Op = enum(u8) {
        transfer,
        duplicate,
        _,
    };

    pub fn isValid(transfer: HandleTransfer) bool {
        if (!transfer.rights.isValid()) return false;
        switch (transfer.op) {
            _ => return false,
            else => {},
        }

        return true;
    }
};

pub const VmarMapOpts = packed struct {
    placement: Placement = .normal,
    perm: Permission = .ro,

    pub const Placement = enum(u2) {
        normal,
        fixed,
        fixed_overwrite,
        _,
    };

    pub const Permission = enum(u2) {
        ro,
        rw,
        rx,
        _,
    };

    const Backing = @Int(.unsigned, @bitSizeOf(VmarMapOpts));
    pub fn fromUsize(int: usize) !VmarMapOpts {
        if (int > std.math.maxInt(Backing)) return error.BadArg;
        const opts: VmarMapOpts = @bitCast(@as(Backing, @intCast(int)));
        switch (opts.placement) {
            _ => return error.BadArg,
            else => {},
        }
        switch (opts.perm) {
            _ => return error.BadArg,
            else => {},
        }
        return opts;
    }

    pub fn toUsize(opts: VmarMapOpts) usize {
        return @as(Backing, @bitCast(opts));
    }
};

pub const ThreadStartInfo = extern struct {
    ip: usize,
    sp: usize,
    args: [6]usize,
};

pub const KLogEntry = extern struct {
    id: u64,
    /// null terminated or 8 long
    scope: [max_klog_scope]u8,
    flags: Flags,

    pub const Flags = packed struct(u8) {
        level: Level,
        truncated: bool,
        unused: u5 = 0,
    };

    pub const Level = enum(u2) {
        err,
        warn,
        info,
        debug,
    };
};

pub const ResourceKind = enum(u8) {
    klog_backend_serial,
    x86_ioports,
};

pub const HandleCloseError = error{BadHandle};
pub const HandleDuplicateError = error{ BadHandle, OutOfMemory, TooManyHandles, BadArg, NoRight };

pub const SocketCreatePairError = error{ TooManyHandles, OutOfMemory };
pub const SocketSendError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, IsFull, NoRight };
pub const SocketReceiveError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, IsEmpty, NoRight };

pub const ChannelCreatePairError = error{ TooManyHandles, OutOfMemory };
pub const ChannelSendError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, TooBig, OutOfMemory, BadArg, NoRight };
pub const ChannelReceiveError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, TooBig, OutOfMemory, TooManyHandles, NoRight, IsEmpty };

pub const KLogWriteError = error{ BadHandle, BadHandleKind, Fault, NoRight, BadArg };
pub const KLogReadError = error{ BadHandle, BadHandleKind, Fault, NoRight, IsEmpty };
pub const KLogDisableBackendError = error{ BadHandle, BadHandleKind };

pub const VmoCreateError = error{ OutOfMemory, TooManyHandles };
pub const VmoWriteError = error{ OutOfMemory, BadHandle, BadHandleKind, OutOfRange, NoRight, Fault };
pub const VmoReadError = error{ BadHandle, BadHandleKind, OutOfRange, NoRight, Fault };
pub const VmoGetSizeError = error{ BadHandle, BadHandleKind };

pub const VmarMapError = error{ BadHandle, BadHandleKind, NoRight, BadArg, NotAligned, OutOfRange, NoGap, OutOfMemory };

pub const ProcessCreateError = error{ OutOfMemory, TooManyHandles };
pub const ProcessTransferHandlesError = error{ OutOfMemory, TooManyHandles, BadHandle, BadHandleKind, TooBig, Fault, BadArg, NoRight, BadState };

pub const ThreadCreateError = error{ BadHandle, BadHandleKind, OutOfMemory, TooManyHandles };
pub const ThreadStartError = error{ BadHandle, BadHandleKind, Fault, BadState, BadArg, OutOfMemory };

pub const ResourceCloneError = error{ BadHandle, BadHandleKind, NoRight, OutOfMemory, TooManyHandles };

pub const X86IoPortsAcquireError = error{ BadHandle, BadHandleKind, NoRight, OutOfMemory };
