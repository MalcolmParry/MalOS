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

    fopen,
    fread,
    fwrite,
    exit,
};

pub const Status = enum(usize) {
    success,

    bad_syscall,
    bad_arg,
    fault,
    path_too_long,
    too_many_handles,
    io,
    corrupt,
    out_of_memory,
    invalid_name,
    not_a_dir,
    is_a_dir,
    name_too_long,
    no_entry,
    read_only,
    not_supported,
    bad_handle,
    bad_handle_kind,
    bad_access,
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

pub const Access = packed struct {
    r: bool = false,
    w: bool = false,
    x: bool = false,

    pub const ro: Access = .{ .r = true };
    pub const wo: Access = .{ .w = true };
    pub const rw: Access = .{ .r = true, .w = true };
    pub const rwx: Access = .{ .r = true, .w = true, .x = true };
};

pub const FOpenFlags = packed struct {
    access: Access = .ro,

    const Backing = @Int(.unsigned, @bitSizeOf(FOpenFlags));
    pub fn toUsize(flags: FOpenFlags) usize {
        return @as(Backing, @bitCast(flags));
    }

    pub fn fromUsize(int: usize) !FOpenFlags {
        if (int > std.math.maxInt(Backing)) return error.BadArg;
        return @bitCast(@as(Backing, @intCast(int)));
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
