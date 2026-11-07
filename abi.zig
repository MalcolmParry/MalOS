const std = @import("std");

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

    vmo_create,
    vmo_write,
    vmo_read,
    vmo_get_size,

    vmar_map,

    process_create,

    thread_create,
    thread_start,
    thread_exit,
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
    _,

    pub const max = std.math.maxInt(u32);
    pub fn fromUsize(int: usize) !Handle {
        if (int > max) return error.BadHandle;
        return @enumFromInt(int);
    }
};

pub const Rights = packed struct {
    duplicate: bool = false,
    transfer: bool = false,
    read: bool = false,
    write: bool = false,
    exec: bool = false,
    transfer_to: bool = false,

    const Backing = @Int(.unsigned, @bitSizeOf(Rights));
    pub fn fromUsize(int: usize) !Rights {
        if (int > std.math.maxInt(Backing)) return error.BadArg;
        return @bitCast(@as(Backing, @intCast(int)));
    }

    pub fn toUsize(rights: Rights) usize {
        return @as(Backing, @bitCast(rights));
    }

    pub fn intersect(left: Rights, right: Rights) Rights {
        return @bitCast(@as(Backing, @bitCast(left)) & @as(Backing, @bitCast(right)));
    }

    pub fn hasAll(left: Rights, right: Rights) bool {
        return left.intersect(right) == right;
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

pub const HandleCloseError = error{BadHandle};
pub const HandleDuplicateError = error{ BadHandle, OutOfMemory, TooManyHandles, BadArg, NoRight };

pub const SocketCreatePairError = error{ TooManyHandles, OutOfMemory };
pub const SocketSendError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, IsFull, NoRight };
pub const SocketReceiveError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, IsEmpty, NoRight };

pub const ChannelCreatePairError = error{ TooManyHandles, OutOfMemory };
pub const ChannelSendError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, TooBig, OutOfMemory, BadArg, NoRight };
pub const ChannelReceiveError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, TooBig, OutOfMemory, TooManyHandles, NoRight };

pub const KLogWriteError = error{ BadHandle, BadHandleKind, Fault, NoRight };

pub const VmoCreateError = error{ OutOfMemory, TooManyHandles };
pub const VmoWriteError = error{ OutOfMemory, BadHandle, BadHandleKind, OutOfRange, NoRight, Fault };
pub const VmoReadError = error{ BadHandle, BadHandleKind, OutOfRange, NoRight, Fault };
pub const VmoGetSizeError = error{ BadHandle, BadHandleKind };

pub const VmarMapError = error{ BadHandle, BadHandleKind, NoRight, BadArg, NotAligned, OutOfRange, NoGap, OutOfMemory };

pub const ProcessCreateError = error{ OutOfMemory, TooManyHandles };

pub const ThreadCreateError = error{ BadHandle, BadHandleKind, OutOfMemory, TooManyHandles };
pub const ThreadStartError = error{ BadHandle, BadHandleKind, Fault, BadState, BadArg };
