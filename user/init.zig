const std = @import("std");
const lib = @import("lib");
const abi = @import("abi");

pub const panic = std.debug.FullPanic(lib.panic);
pub const std_options: std.Options = .{
    .logFn = lib.log,
};

pub fn main(initrd: abi.Handle) !void {
    _ = initrd;
    // lib.syscall.handleClose(initrd) catch @panic("failed to close handle");
    std.log.info("hello world", .{});

    {
        const h0, const h1 = try lib.syscall.channelCreatePair();
        defer {
            lib.syscall.handleClose(h0) catch @panic("failed to close handle");
            lib.syscall.handleClose(h1) catch @panic("failed to close handle");
        }

        try lib.syscall.channelSend(h0, "msg from channel\n", &.{});

        var buffer: [128]u8 = undefined;
        const bytes, _ = try lib.syscall.channelReceive(h1, &buffer, &.{});
        lib.syscall.klogWrite(lib.klog, buffer[0..bytes]) catch {};
    }

    for ("direct writing to serial in userspace\r\n") |c| outb(0x3f8, c);

    {
        const h0, const h1 = try lib.syscall.socketCreatePair();
        defer {
            lib.syscall.handleClose(h0) catch @panic("failed to close handle");
            lib.syscall.handleClose(h1) catch @panic("failed to close handle");
        }

        var msg_to_send: []const u8 = "message from socket\n";
        while (msg_to_send.len != 0) {
            const sent = try lib.syscall.socketSend(h0, msg_to_send);
            msg_to_send = msg_to_send[sent..];
        }

        var buffer: [256]u8 = undefined;
        const read = try lib.syscall.socketReceive(h1, &buffer);
        lib.syscall.klogWrite(lib.klog, buffer[0..read]) catch {};
    }

    const disk = getDrive(.{
        .io_base = 0x1f0,
        .kind = .master,
    }) orelse return error.NoDisk;

    var sector: [sector_size * 2]u8 = undefined;
    try readSectors(disk, 1024 * 2 + 2, &sector);

    const bytes_per_group = 2;
    const groups_per_line = 8;
    const lines = (sector_size * 2) / bytes_per_group / groups_per_line;

    var offset: usize = 0;
    for (0..lines) |_| {
        var buffer: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        for (0..groups_per_line) |_| {
            for (0..bytes_per_group) |_| {
                try writer.print("{x:0>2}", .{sector[offset]});
                offset += 1;
            }

            try writer.print(" ", .{});
        }

        try writer.print("\n", .{});
        try lib.syscall.klogWrite(lib.klog, writer.buffered());
    }

    lib.syscall.exit(0);
}

fn outb(port: u16, data: u8) void {
    asm volatile (
        \\ outb %[data], %[port]
        :
        : [port] "{dx}" (port),
          [data] "{al}" (data),
    );
}

pub fn in(comptime T: type, port: u16) T {
    return switch (@bitSizeOf(T)) {
        8 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> T),
            : [port] "N{dx}" (port),
        ),
        16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> T),
            : [port] "N{dx}" (port),
        ),
        32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> T),
            : [port] "N{dx}" (port),
        ),
        else => @compileError("bit size of type must be 8, 16, or 32. found " ++ @typeName(T)),
    };
}

pub fn repInsw(port: u16, buffer: []align(1) u16) void {
    asm volatile (
        \\ cld
        \\ rep insw
        :
        : [port] "{dx}" (port),
          [buffer] "{rdi}" (buffer.ptr),
          [count] "{rcx}" (buffer.len),
        : .{ .rdi = true, .rcx = true, .memory = true, .dirflag = true });
}

comptime {
    _ = lib;
}

const sector_size = 512;

pub const Drive = struct {
    io_base: u16,
    kind: Kind,

    pub const Kind = enum {
        master,
        slave,
    };

    pub const Desc = struct {
        io_base: u16,
        kind: Kind,
    };
};

const Status = packed struct(u8) {
    err: bool,
    idx: bool,
    corr: bool,
    drq: bool,
    srv: bool,
    df: bool,
    rdy: bool,
    bsy: bool,
};

pub fn getDrive(desc: Drive.Desc) ?Drive {
    const io_base = desc.io_base;
    const kind = desc.kind;

    outb(io_base + 6, switch (kind) {
        .master => 0xa0,
        .slave => 0xb0,
    });

    outb(io_base + 2, 0);
    outb(io_base + 3, 0);
    outb(io_base + 4, 0);
    outb(io_base + 5, 0);

    outb(io_base + 7, 0xec);
    if (in(u8, io_base + 7) == 0) return null;

    var timeout: u32 = 100_000;
    while (in(Status, io_base + 7).bsy) {
        timeout -= 1;
        if (timeout == 0) return null;
    }

    if (in(u8, io_base + 4) != 0 or in(u8, io_base + 5) != 0) return null;

    while (true) {
        const status = in(Status, io_base + 7);

        if (status.bsy) {
            std.log.err("drive busy", .{});
            return null;
        }

        if (status.err) {
            std.log.err("drive error", .{});
            return null;
        }

        if (status.drq) break;
    }

    var identity: [256]u16 = undefined;
    repInsw(io_base, &identity);

    if (identity[83] & (1 << 10) == 0) {
        std.log.err("drive doesn't support lba48", .{});
        return null;
    }

    const sector_count = blk: {
        const w0: u64 = identity[100];
        const w1: u64 = identity[101];
        const w2: u64 = identity[102];
        const w3: u64 = identity[103];
        break :blk w0 | (w1 << 16) | (w2 << 32) | (w3 << 48);
    };
    _ = sector_count;

    return .{
        .io_base = io_base,
        .kind = kind,
    };
}

fn readSectors(drive: Drive, first_sector: u64, buffer: []u8) !void {
    const sector_count = @divExact(buffer.len, sector_size);
    const io_base = drive.io_base;
    outb(io_base + 6, switch (drive.kind) {
        .master => 0x40,
        .slave => 0x50,
    });

    outb(io_base + 2, @truncate(sector_count >> 8));
    outb(io_base + 3, @truncate(first_sector >> 24));
    outb(io_base + 4, @truncate(first_sector >> 32));
    outb(io_base + 5, @truncate(first_sector >> 40));

    outb(io_base + 2, @truncate(sector_count));
    outb(io_base + 3, @truncate(first_sector));
    outb(io_base + 4, @truncate(first_sector >> 8));
    outb(io_base + 5, @truncate(first_sector >> 16));

    outb(io_base + 7, 0x24);

    for (0..sector_count) |i| {
        try poll(io_base);

        const word_ptr: [*]align(1) u16 = @ptrCast(buffer.ptr + i * sector_size);
        repInsw(io_base, word_ptr[0..256]);
    }
}

fn poll(io_base: u16) !void {
    while (true) {
        const status = in(Status, io_base + 7);
        if (status.bsy) continue;
        if (status.err or status.df) return error.Io;
        if (status.drq) return;
        return error.Io;
    }
}
