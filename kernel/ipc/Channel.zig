const std = @import("std");
const gpa = @import("../heap/gpa.zig").allocator;
const Task = @import("../task/Task.zig");
const Spinlock = @import("../sync/Spinlock.zig");
const Channel = @This();

lock: Spinlock,
first_msg: ?*Message,
last_msg: ?*Message,
closed: bool,
ref_count: std.atomic.Value(u32),

pub const max_bytes = 1024 * 16;
pub const max_handles = 16;

pub const Pair = struct {
    ends: [2]Channel,
    ref_count: std.atomic.Value(u32),

    pub fn create() !*Pair {
        const pair = try gpa.create(Pair);
        pair.* = .{
            .ends = @splat(.{
                .lock = .init,
                .first_msg = null,
                .last_msg = null,
                .closed = false,
                .ref_count = .init(1),
            }),
            .ref_count = .init(2),
        };
        return pair;
    }
};

pub const Message = struct {
    next: ?*Message = null,
    destroy_ptr: *const fn (msg: *Message) void,
    bytes: []const u8,
    handles: []const Task.HandleDesc,

    pub fn destroy(msg: *Message) void {
        for (msg.handles) |d| d.release();
        msg.destroy_ptr(msg);
    }

    pub fn destroyNoReleaseHandles(msg: *Message) void {
        msg.destroy_ptr(msg);
    }
};

pub const Desc = struct {
    pair: *Pair,
    end: u1,

    pub fn get(desc: Desc) *Channel {
        return &desc.pair.ends[desc.end];
    }

    pub fn getPeer(desc: Desc) *Channel {
        return &desc.pair.ends[desc.end +% 1];
    }

    pub fn acquire(desc: Desc) void {
        const prev = desc.get().ref_count.fetchAdd(1, .monotonic);
        std.debug.assert(prev != 0);
    }

    pub fn release(desc: Desc) void {
        const channel = desc.get();
        const prev = channel.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(prev != 0);
        if (prev != 1) return;

        const first = blk: {
            const l = channel.lock.lock();
            defer l.unlock();
            channel.closed = true;
            const first = channel.first_msg;
            channel.first_msg = null;
            channel.last_msg = null;
            break :blk first;
        };

        var maybe_msg = first;
        while (maybe_msg) |msg| {
            maybe_msg = msg.next;
            msg.destroy();
        }

        const prev_pair = desc.pair.ref_count.fetchSub(1, .acq_rel);
        std.debug.assert(prev_pair != 0);
        if (prev_pair == 1) {
            gpa.destroy(desc.pair);
            return;
        }

        // TODO: wake peers waiters
    }

    pub fn send(desc: Desc, msg: *Message) !void {
        const peer = desc.getPeer();
        const l = peer.lock.lock();
        defer l.unlock();
        if (peer.closed) return error.PeerClosed;

        if (peer.last_msg) |last| {
            last.next = msg;
        }

        if (peer.first_msg == null) {
            peer.first_msg = msg;
        }

        msg.next = null;
        peer.last_msg = msg;
    }

    pub fn receive(desc: Desc, byte_limit: usize, desc_limit: usize) error{TooBig}!?*Message {
        const channel = desc.get();
        const l = channel.lock.lock();
        defer l.unlock();

        const msg = channel.first_msg orelse return null;
        if (msg.bytes.len > byte_limit) return error.TooBig;
        if (msg.handles.len > desc_limit) return error.TooBig;

        channel.first_msg = msg.next;
        if (msg.next == null) channel.last_msg = null;
        return msg;
    }
};
