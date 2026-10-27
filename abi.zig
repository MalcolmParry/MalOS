const std = @import("std");

pub const Syscall = enum(usize) {
    handle_close,
    handle_clone,

    channel_create_pair,
    channel_send,
    channel_receive,

    socket_create_pair,
    socket_send,
    socket_receive,

    klog_write,

    exit,
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
};

pub const Handle = enum(u32) {
    _,

    pub const max = std.math.maxInt(u32);
    pub fn fromUsize(int: usize) !Handle {
        if (int > max) return error.BadHandle;
        return @enumFromInt(int);
    }
};

pub const HandleCloseError = error{BadHandle};
pub const HandleCloneError = error{ BadHandle, OutOfMemory };

pub const SocketCreatePairError = error{ TooManyHandles, OutOfMemory };
pub const SocketSendError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, IsFull };
pub const SocketReceiveError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, IsEmpty };

pub const ChannelCreatePairError = error{ TooManyHandles, OutOfMemory };
pub const ChannelSendError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, TooBig, OutOfMemory, BadArg };
pub const ChannelReceiveError = error{ BadHandle, BadHandleKind, Fault, PeerClosed, TooBig, OutOfMemory, TooManyHandles };

pub const KLogWriteError = error{ BadHandle, BadHandleKind, Fault };
