const std = @import("std");
const lib = @import("lib");
const abi = @import("abi");

var klog: abi.Handle = undefined;

pub fn main(klog_: abi.Handle) noreturn {
    klog = klog_;
    print("hello world\n");

    {
        const h0, const h1 = lib.syscall.channelCreatePair() catch panic("failed to create channel pair");
        defer {
            lib.syscall.handleClose(h0) catch panic("failed to close handle");
            lib.syscall.handleClose(h1) catch panic("failed to close handle");
        }

        lib.syscall.channelSend(h0, "msg from channel\n", &.{}) catch panic("failed to send over channel");

        var buffer: [128]u8 = undefined;
        const bytes, _ = lib.syscall.channelReceive(h1, &buffer, &.{}) catch panic("failed to receive over channel");
        print(buffer[0..bytes]);
    }

    for ("direct writing to serial in userspace\n") |c| out(0x3f8, c);

    {
        const h0, const h1 = lib.syscall.socketCreatePair() catch panic("failed to create socket pair");
        defer {
            lib.syscall.handleClose(h0) catch panic("failed to close handle");
            lib.syscall.handleClose(h1) catch panic("failed to close handle");
        }

        var msg_to_send: []const u8 = "message from socket\n";
        while (msg_to_send.len != 0) {
            const sent = lib.syscall.socketSend(h0, msg_to_send) catch panic("failed to send");
            msg_to_send = msg_to_send[sent..];
        }

        var buffer: [256]u8 = undefined;
        const read = lib.syscall.socketReceive(h1, &buffer) catch panic("failed to read from socket");
        print(buffer[0..read]);
    }

    lib.syscall.exit(0);
}

fn print(msg: []const u8) void {
    lib.syscall.klogWrite(klog, msg) catch {};
}

fn panic(msg: []const u8) noreturn {
    print(msg);
    lib.syscall.exit(1);
}

pub fn out(port: u16, data: anytype) void {
    switch (@bitSizeOf(@TypeOf(data))) {
        8 => asm volatile ("outb %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{al}" (data),
        ),
        16 => asm volatile ("outw %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{ax}" (data),
        ),
        32 => asm volatile ("outl %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{eax}" (data),
        ),
        else => @compileError("bit size of type must be 8, 16, or 32. found " ++ @typeName(@TypeOf(data))),
    }
}

comptime {
    _ = lib;
}
