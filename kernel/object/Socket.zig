const std = @import("std");
const arch = @import("../arch/arch.zig").current;
const mem = @import("../memory.zig");
const pmm = @import("../pmm.zig");
const Object = @import("Object.zig");
const Spinlock = @import("../sync/Spinlock.zig");
const gpa = @import("../heap/gpa.zig").allocator;
const Socket = @This();

const buffer_size = mem.page_size;

obj: Object,
lock: Spinlock,
end: u1,
read_offset: usize,
write_offset: usize,
buffer: pmm.Index,

pub const Pair = struct {
    end0: Socket,
    end1: Socket,
    ref_count: std.atomic.Value(u32),

    pub fn create() !*Pair {
        const buffer0 = try pmm.allocPage();
        errdefer pmm.freePage(buffer0);
        const buffer1 = try pmm.allocPage();
        errdefer pmm.freePage(buffer1);

        const pair = try gpa.create(Pair);
        pair.* = .{
            .end0 = .{
                .obj = .{
                    .kind = .socket,
                    .ref_count = .init(1),
                },
                .lock = .init,
                .end = 0,
                .read_offset = 0,
                .write_offset = 0,
                .buffer = buffer0,
            },
            .end1 = .{
                .obj = .{
                    .kind = .socket,
                    .ref_count = .init(1),
                },
                .lock = .init,
                .end = 1,
                .read_offset = 0,
                .write_offset = 0,
                .buffer = buffer1,
            },
            .ref_count = .init(2),
        };
        return pair;
    }
};

pub fn getPair(sock: *Socket) *Pair {
    return switch (sock.end) {
        0 => @fieldParentPtr("end0", sock),
        1 => @fieldParentPtr("end1", sock),
    };
}

pub fn getPeer(sock: *Socket) *Socket {
    const pair = sock.getPair();
    return switch (sock.end) {
        0 => &pair.end1,
        1 => &pair.end0,
    };
}

pub fn destroyEnd(sock: *Socket) void {
    const l = sock.lock.lock();
    pmm.freePage(sock.buffer);
    sock.buffer = undefined;
    l.unlock();
    const pair = sock.getPair();

    const prev = pair.ref_count.fetchSub(1, .acq_rel);
    std.debug.assert(prev != 0);
    if (prev != 1) return;
    gpa.destroy(pair);
}

pub fn sendUser(sock: *Socket, user_data: []allowzero const u8) !usize {
    if (user_data.len == 0) return 0;

    const peer = sock.getPeer();
    const l = peer.lock.lock();
    defer l.unlock();
    if (peer.obj.ref_count.load(.monotonic) == 0) return error.PeerClosed;

    const used_bytes = peer.write_offset - peer.read_offset;
    const free_bytes = buffer_size - used_bytes;
    if (free_bytes == 0) return error.IsFull;
    const to_send = @min(user_data.len, free_bytes);

    const buffer: []u8 = &peer.buffer.toDirectMap().bytes;
    const first_byte = peer.write_offset % buffer_size;
    const full_upper = buffer[first_byte..];
    const upper = full_upper[0..@min(to_send, full_upper.len)];
    if (!arch.copyFromUser(upper, user_data[0..upper.len])) return error.Fault;

    const rest = to_send - upper.len;
    if (!arch.copyFromUser(buffer[0..rest], user_data[upper.len..])) return error.Fault;

    peer.write_offset += to_send;
    return to_send;
}

pub fn receiveUser(sock: *Socket, user_buffer: []allowzero u8) !usize {
    if (user_buffer.len == 0) return 0;

    const l = sock.lock.lock();
    defer l.unlock();

    const used = sock.write_offset - sock.read_offset;
    if (used == 0) return if (sock.getPeer().obj.ref_count.load(.monotonic) == 0) error.PeerClosed else error.IsEmpty;
    const user_to_read = user_buffer[0..@min(user_buffer.len, used)];

    const buffer: []u8 = &sock.buffer.toDirectMap().bytes;
    const first_byte = sock.read_offset % buffer_size;
    const full_upper = buffer[first_byte..];
    const upper = full_upper[0..@min(user_to_read.len, full_upper.len)];
    if (!arch.copyToUser(user_to_read[0..upper.len], upper)) return error.Fault;

    const rest = user_to_read.len - upper.len;
    if (!arch.copyToUser(user_to_read[upper.len..], buffer[0..rest])) return error.Fault;

    sock.read_offset += user_to_read.len;
    return user_to_read.len;
}
