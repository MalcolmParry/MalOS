const std = @import("std");
const abi = @import("abi").syscall;
const pmm = @import("../mem/pmm.zig");
const mem = @import("../mem/memory.zig");
const gpa = @import("../mem/gpa.zig").allocator;
const Spinlock = @import("../sync/Spinlock.zig");
const Object = @import("Object.zig");
const HandleTable = @import("../proc/HandleTable.zig");
const Channel = @This();

obj: Object,
lock: Spinlock,
end: u1,
closed: bool,
first_msg: ?*Message,
last_msg: ?*Message,

const max_bytes = abi.max_channel_msg_bytes;
const max_handles = abi.max_channel_msg_handles;
const msg_page_count = @divCeil(max_bytes, mem.page_size);

pub const Pair = struct {
    end0: Channel,
    end1: Channel,
    ref_count: std.atomic.Value(u32),

    pub fn create() !*Pair {
        const pair = try gpa.create(Pair);
        pair.* = .{
            .end0 = .{
                .obj = .{
                    .kind = .channel,
                    .ref_count = .init(1),
                },
                .lock = .init,
                .end = 0,
                .closed = false,
                .first_msg = null,
                .last_msg = null,
            },
            .end1 = .{
                .obj = .{
                    .kind = .channel,
                    .ref_count = .init(1),
                },
                .lock = .init,
                .end = 1,
                .closed = false,
                .first_msg = null,
                .last_msg = null,
            },
            .ref_count = .init(2),
        };
        return pair;
    }

    pub fn end(pair: *Pair, i: u1) *Channel {
        return switch (i) {
            0 => &pair.end0,
            1 => &pair.end1,
        };
    }
};

pub const Message = struct {
    next: ?*Message = null,
    data_size: u32,
    desc_count: u32,
    data_pages: [msg_page_count]pmm.Index,
    descs: [max_handles]HandleTable.Desc,

    pub fn destroy(msg: *Message) void {
        for (msg.descs[0..msg.desc_count]) |d| d.obj.release();
        msg.destroyNoReleaseHandles();
    }

    pub fn destroyNoReleaseHandles(msg: *Message) void {
        for (msg.data_pages[0..@divCeil(msg.data_size, mem.page_size)]) |page| pmm.freePage(page);
        gpa.destroy(msg);
    }
};

pub fn getPair(channel: *Channel) *Pair {
    return switch (channel.end) {
        0 => @fieldParentPtr("end0", channel),
        1 => @fieldParentPtr("end1", channel),
    };
}

pub fn getPeer(channel: *Channel) *Channel {
    return channel.getPair().end(channel.end +% 1);
}

pub fn destroyEnd(channel: *Channel) void {
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

    // TODO: wake peers waiters

    const pair = channel.getPair();
    const prev = pair.ref_count.fetchSub(1, .acq_rel);
    std.debug.assert(prev != 0);
    if (prev == 1) {
        gpa.destroy(pair);
        return;
    }
}

pub fn send(channel: *Channel, msg: *Message) !void {
    const peer = channel.getPeer();
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

pub fn receive(channel: *Channel, byte_limit: usize, desc_limit: usize) error{TooBig}!?*Message {
    const l = channel.lock.lock();
    defer l.unlock();

    const msg = channel.first_msg orelse return null;
    if (msg.data_size > byte_limit) return error.TooBig;
    if (msg.desc_count > desc_limit) return error.TooBig;

    channel.first_msg = msg.next;
    if (msg.next == null) channel.last_msg = null;
    return msg;
}
