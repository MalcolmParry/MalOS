const std = @import("std");
const Channel = @import("Channel.zig");
const Socket = @import("Socket.zig");
const Vmo = @import("Vmo.zig");
const Vmar = @import("Vmar.zig");
const Process = @import("../proc/Process.zig");
const Thread = @import("../proc/Thread.zig");
const Object = @This();

kind: Kind,
ref_count: std.atomic.Value(u32),

pub const Kind = enum {
    channel,
    socket,
    klog,

    process,
    thread,

    vmo,
    vmar,

    pub fn fromType(comptime T: type) Kind {
        return switch (T) {
            Channel => .channel,
            Socket => .socket,
            Process => .process,
            Thread => .thread,
            Vmo => .vmo,
            Vmar => .vmar,
            else => @compileError("bad type"),
        };
    }
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
        .channel => obj.getAssertKind(Channel).destroyEnd(),
        .socket => obj.getAssertKind(Socket).destroyEnd(),
        .klog => {},
        .process => obj.getAssertKind(Process).destroy(),
        .thread => obj.getAssertKind(Thread).destroy(),
        .vmo => obj.getAssertKind(Vmo).destroy(),
        .vmar => obj.getAssertKind(Vmar).destroy(),
    }
}

pub fn get(obj: *Object, T: type) ?*T {
    if (obj.kind != Kind.fromType(T)) return null;
    return @alignCast(@fieldParentPtr("obj", obj));
}

pub fn getAssertKind(obj: *Object, T: type) *T {
    std.debug.assert(obj.kind == Kind.fromType(T));
    return @alignCast(@fieldParentPtr("obj", obj));
}
