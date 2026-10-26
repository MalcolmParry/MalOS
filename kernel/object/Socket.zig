const std = @import("std");
const Object = @import("Object.zig");
const Spinlock = @import("../sync/Spinlock.zig");
const gpa = @import("../heap/gpa.zig").allocator;
const Socket = @This();

const buffer_size = 1024 * 4;

obj: Object,
lock: Spinlock,
end: u1,
read_offset: usize,
write_offset: usize,
buffer: [buffer_size]u8,

pub const Pair = struct {
    end0: Socket,
    end1: Socket,
    ref_count: std.atomic.Value(u32),

    pub fn create() !*Pair {
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
                .buffer = undefined,
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
                .buffer = undefined,
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
    const pair = sock.getPair();
    const prev = pair.ref_count.fetchSub(1, .acq_rel);
    std.debug.assert(prev != 0);
    if (prev != 1) return;
    gpa.destroy(pair);
}

pub fn send(sock: *Socket, data: []const u8) !usize {
    if (data.len == 0) return 0;

    const peer = sock.getPeer();
    const l = peer.lock.lock();
    defer l.unlock();
    if (peer.obj.ref_count.load(.acquire) == 0) return error.PeerClosed;

    const used_bytes = peer.write_offset - peer.read_offset;
    const free_bytes = buffer_size - used_bytes;
    if (free_bytes == 0) return error.IsFull;
    const to_send = @min(data.len, free_bytes);

    const first_byte = peer.write_offset % buffer_size;
    const full_upper = peer.buffer[first_byte..];
    const upper = full_upper[0..@min(to_send, full_upper.len)];
    @memcpy(upper, data[0..upper.len]);

    const rest = to_send - upper.len;
    @memcpy(peer.buffer[0..rest], data[upper.len..]);

    peer.write_offset += to_send;
    return to_send;
}

pub fn receive(sock: *Socket, buffer: []u8) !usize {
    if (buffer.len == 0) return 0;

    const l = sock.lock.lock();
    defer l.unlock();

    const used = sock.write_offset - sock.read_offset;
    if (used == 0) return if (sock.getPeer().obj.ref_count.load(.acquire) == 0) error.PeerClosed else error.IsEmpty;
    const to_read = buffer[0..@min(buffer.len, used)];

    const first_byte = sock.read_offset % buffer_size;
    const full_upper = sock.buffer[first_byte..];
    const upper = full_upper[0..@min(to_read.len, full_upper.len)];
    @memcpy(to_read[0..upper.len], upper);

    const rest = to_read.len - upper.len;
    @memcpy(to_read[upper.len..], sock.buffer[0..rest]);

    sock.read_offset += to_read.len;
    return to_read.len;
}
