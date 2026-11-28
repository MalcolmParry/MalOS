const std = @import("std");
const lib = @import("lib");
const abi = lib.abi;

pub const panic = std.debug.FullPanic(lib.panic);
pub const std_options: std.Options = .{
    .logFn = lib.log,
};

comptime {
    _ = lib;
}

pub fn main(_: lib.Handle) !void {
    const serial_backend = (lib.getResource(.klog_backend_serial, 0, 0) orelse @panic("no klog serial backend resource")).handle;
    const ioports = lib.getResource(.x86_ioports, 0x3f8, 8) orelse @panic("no ioports resource");
    try lib.syscall.x86IoPortsAcquire(ioports.handle, 0x3f8, 8);

    const last_entry = try lib.syscall.klogDisableBackend(serial_backend);

    while (true) {
        var read_buffer: [abi.syscall.max_klog_entry]u8 align(@alignOf(abi.syscall.KLogEntry)) = undefined;
        const header: *abi.syscall.KLogEntry = @ptrCast(&read_buffer);
        const len = lib.syscall.klogRead(lib.klog, &read_buffer) catch |err| return switch (err) {
            error.IsEmpty => {
                lib.syscall.sleepNs(std.time.ns_per_ms);
                continue;
            },
            else => |x| x,
        };

        if (header.id < last_entry) continue;
        const scope = std.mem.sliceTo(@as([]const u8, &header.scope), 0);
        const t: std.Io.Terminal = .{ .writer = &serial_writer, .mode = .escape_codes };

        t.setColor(.reset) catch {};
        t.setColor(switch (header.flags.level) {
            .err => .red,
            .warn => .yellow,
            .info => .green,
            .debug => .magenta,
        }) catch {};

        t.setColor(.bold) catch {};
        try t.writer.writeAll(@tagName(header.flags.level));
        t.setColor(.reset) catch {};
        t.setColor(.dim) catch {};
        t.setColor(.bold) catch {};
        if (scope.len != 0) try t.writer.print("({s})", .{scope});
        try t.writer.writeAll(": ");
        t.setColor(.reset) catch {};

        try t.writer.writeAll(read_buffer[@sizeOf(abi.syscall.KLogEntry)..][0..len]);
        try t.writer.writeAll("\n");
        if (header.flags.truncated) {
            t.setColor(.reset) catch {};
            t.setColor(.dim) catch {};
            t.writer.print("(message truncated)\n", .{}) catch {};
        }
    }
}

fn isTransmitEmpty() bool {
    return in(u8, 0x3f8 + 5) & 0x20 > 0;
}

pub fn writeByte(byte: u8) void {
    while (!isTransmitEmpty()) {
        std.atomic.spinLoopHint();
    }

    outb(0x3f8, byte);
}

pub fn writeStr(str: []const u8) void {
    for (str) |c| switch (c) {
        '\n' => write("\r\n"),
        else => writeByte(c),
    };
}

pub fn write(data: []const u8) void {
    for (data) |byte| writeByte(byte);
}

fn drain(this: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
    this.end = 0;
    var written: usize = 0;

    for (data[0 .. data.len - 1]) |x| {
        writeStr(x);
        written += x.len;
    }

    const pattern = data[data.len - 1];
    for (0..splat) |_| {
        writeStr(pattern);
        written += pattern.len;
    }

    return written;
}

var serial_writer: std.Io.Writer = .{ .vtable = &.{ .drain = &drain }, .buffer = &.{} };

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
