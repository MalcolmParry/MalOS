const std = @import("std");
const Channel = @import("Channel.zig");
const Socket = @import("Socket.zig");
const Object = @This();

kind: Kind,
ref_count: std.atomic.Value(u32),

pub const Kind = enum {
    channel,
    socket,
};

pub fn acquire(obj: *Object) void {
    const prev = obj.ref_count.fetchAdd(1, .monotonic);
    std.debug.assert(prev != 0);
}

pub fn release(obj: *Object) void {
    const prev = obj.ref_count.fetchSub(1, .acq_rel);
    std.debug.assert(prev != 0);
    if (prev != 1) return;

    switch (obj.kind) {
        .channel => {
            const channel = obj.getChannel() orelse unreachable;
            channel.destroyEnd();
        },
        .socket => {
            const socket = obj.getSocket() orelse unreachable;
            socket.destroyEnd();
        },
    }
}

pub fn getChannel(obj: *Object) ?*Channel {
    if (obj.kind != .channel) return null;
    return @alignCast(@fieldParentPtr("obj", obj));
}

pub fn getSocket(obj: *Object) ?*Socket {
    if (obj.kind != .socket) return null;
    return @alignCast(@fieldParentPtr("obj", obj));
}
