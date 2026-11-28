const std = @import("std");
const lib = @import("lib");
const abi = @import("abi");
const shared = @import("shared");
const Handle = abi.syscall.Handle;

const outb = shared.arch.outb;
const in = shared.arch.in;
const repInsw = shared.arch.repInsw;

pub const panic = std.debug.FullPanic(lib.panic);
pub const std_options: std.Options = .{
    .logFn = lib.log,
};

comptime {
    _ = lib;
}

pub fn main(initrd: Handle) !void {
    const ioports = (lib.getResource(.x86_ioports, 0, 65536) orelse @panic("no ioports resource")).handle;

    const initrd_size = try lib.syscall.vmoGetSize(initrd);
    try lib.syscall.x86IoPortsAcquire(ioports, 0x1f0, 8);

    {
        const proc, const vmar = try lib.syscall.processCreate();
        defer {
            lib.syscall.handleClose(vmar) catch unreachable;
            lib.syscall.handleClose(proc) catch unreachable;
        }

        const initrd_map_ptr = try lib.syscall.vmarMap(lib.vmar, 0, initrd, 0, initrd_size, .{});
        const initrd_map = initrd_map_ptr[0..initrd_size];

        const elf = (try shared.ustar.lookup(initrd_map, "serial")) orelse @panic("cant find serial driver");
        var reader: std.Io.Reader = .fixed(elf);

        const header = try std.elf.Header.read(&reader);
        if (!header.is_64) return error.NotSupported;
        if (header.machine != .X86_64) return error.NotSupported;
        if (header.type != .EXEC) return error.NotSupported;

        const min_load_addr = 4096;
        const page_size = 4096;
        for (0..header.phnum) |i| {
            reader.seek = header.phoff + i * header.phentsize;
            const ph = try reader.takeStruct(std.elf.Elf64.Phdr, header.endian);
            if (ph.type != .LOAD) continue;
            if (ph.filesz > ph.memsz) return error.BadElf;
            if (ph.memsz == 0) continue;
            if (ph.vaddr < min_load_addr) return error.NotSupported;
            if (ph.flags.W and ph.flags.X) return error.NotSupported;

            const first_page = ph.vaddr / page_size;
            const offset_from_page = ph.vaddr % page_size;

            const vmo = try lib.syscall.vmoCreate(ph.memsz + offset_from_page);
            defer lib.syscall.handleClose(vmo) catch unreachable;

            try lib.syscall.vmoWrite(vmo, offset_from_page, elf[ph.offset..][0..ph.filesz]);

            _ = try lib.syscall.vmarMap(vmar, first_page * page_size, vmo, 0, ph.memsz + offset_from_page, .{
                .placement = .fixed,
                .perm = if (ph.flags.W) .rw else if (ph.flags.X) .rx else .ro,
            });
        }

        const stack_size = 32 * 1024;
        const stack_vmo = try lib.syscall.vmoCreate(stack_size);
        defer lib.syscall.handleClose(stack_vmo) catch unreachable;
        const stack = try lib.syscall.vmarMap(vmar, 0, stack_vmo, 0, stack_size, .{ .perm = .rw });

        const args_vmo = try lib.syscall.vmoCreate(16 * 1024);
        defer lib.syscall.handleClose(args_vmo) catch unreachable;

        const limited_ioports = try lib.syscall.resourceClone(ioports, 0x3f8, 8);
        errdefer lib.syscall.handleClose(limited_ioports) catch {};

        var child_handles: [5]Handle = undefined;
        try lib.syscall.processTransferHandles(
            proc,
            &.{
                .{
                    .op = .duplicate,
                    .handle = args_vmo,
                    .rights = .basic_ro,
                },
                .{
                    .op = .duplicate,
                    .handle = vmar,
                    .rights = .basic_rwx,
                },
                .{
                    .op = .duplicate,
                    .handle = lib.klog,
                    .rights = .basic_rw,
                },
                .{
                    .op = .transfer,
                    .handle = (lib.getResource(.klog_backend_serial, 0, 0) orelse @panic("no klog serial backend resource")).handle,
                    .rights = .basic,
                },
                .{
                    .op = .transfer,
                    .handle = limited_ioports,
                    .rights = .basic,
                },
            },
            &child_handles,
        );

        const resource_offset = std.mem.Alignment.of(abi.proc_args.Resource).forward(@sizeOf(abi.proc_args.Header));
        const resources: [2]abi.proc_args.Resource = .{
            .{ .kind = .klog_backend_serial, .handle = child_handles[3], .base = 0, .len = 0 },
            .{ .kind = .x86_ioports, .handle = child_handles[4], .base = 0x3f8, .len = 8 },
        };

        const args_header: abi.proc_args.Header = .{
            .vmar = child_handles[1],
            .klog = child_handles[2],
            .initrd = .invalid,
            .resource_offset = @intCast(resource_offset),
            .resource_count = resources.len,
        };

        try lib.syscall.vmoWrite(args_vmo, 0, std.mem.asBytes(&args_header));
        try lib.syscall.vmoWrite(args_vmo, resource_offset, std.mem.asBytes(&resources));

        const thread = try lib.syscall.threadCreate(proc);
        defer lib.syscall.handleClose(thread) catch unreachable;
        try lib.syscall.threadStart(thread, &.{
            .ip = header.entry,
            .sp = @intFromPtr(stack.ptr) + stack.len - 8,
            .args = .{ @backingInt(child_handles[0]), 0, 0, 0, 0, 0 },
        });
    }

    {
        const h0, const h1 = try lib.syscall.channelCreatePair();
        defer {
            lib.syscall.handleClose(h0) catch @panic("failed to close handle");
            lib.syscall.handleClose(h1) catch @panic("failed to close handle");
        }

        try lib.syscall.channelSend(h0, "msg from channel", &.{});

        var buffer: [128]u8 = undefined;
        const bytes, _ = try lib.syscall.channelReceive(h1, &buffer, &.{});
        lib.syscall.klogWrite(lib.klog, buffer[0..bytes], .info) catch {};
    }

    {
        const h0, const h1 = try lib.syscall.socketCreatePair();
        defer {
            lib.syscall.handleClose(h0) catch @panic("failed to close handle");
            lib.syscall.handleClose(h1) catch @panic("failed to close handle");
        }

        var msg_to_send: []const u8 = "message from socket";
        while (msg_to_send.len != 0) {
            const sent = try lib.syscall.socketSend(h0, msg_to_send);
            msg_to_send = msg_to_send[sent..];
        }

        var buffer: [256]u8 = undefined;
        const read = try lib.syscall.socketReceive(h1, &buffer);
        lib.syscall.klogWrite(lib.klog, buffer[0..read], .info) catch {};
    }

    {
        const size = 64 * 1024;
        const vmo = try lib.syscall.vmoCreate(size);
        defer lib.syscall.handleClose(vmo) catch @panic("failed to close handle");

        const base = 4090;
        const msg = "message written to vmo";
        try lib.syscall.vmoWrite(vmo, base, "   " ++ msg);
        var buffer: [msg.len]u8 = undefined;
        try lib.syscall.vmoRead(vmo, base + 3, &buffer);
        std.log.info("data in vmo: '{s}'", .{&buffer});

        const map_ptr = try lib.syscall.vmarMap(lib.vmar, 0, vmo, 0, size, .{});
        const map = map_ptr[0..size];

        std.log.info("data from vmo map: '{s}'", .{map[base + 3 ..][0..msg.len]});
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

    var buffer: [abi.syscall.max_klog_msg]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    var offset: usize = 0;
    for (0..lines) |_| {
        try writer.print("\n", .{});

        for (0..groups_per_line) |_| {
            for (0..bytes_per_group) |_| {
                try writer.print("{x:0>2}", .{sector[offset]});
                offset += 1;
            }

            try writer.print(" ", .{});
        }
    }

    std.log.info("ext2 superblock:{s}", .{writer.buffered()});
    lib.syscall.threadExit();
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
