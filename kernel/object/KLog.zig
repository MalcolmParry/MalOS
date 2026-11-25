const std = @import("std");
const abi = @import("abi");
const gpa = @import("../mem/gpa.zig").allocator;
const Spinlock = @import("../sync/Spinlock.zig");
const Object = @import("Object.zig");
const Terminal = @import("../tty/Terminal.zig");
const vga_text = @import("../drivers/x86/vga_text.zig");
const boot_info = @import("../boot_info.zig");
const serial = @import("../drivers/x86/serial.zig");
const KLog = @This();

obj: Object,
cur_id: u64,

var lock: Spinlock = .init;
var first_entry: u64 = 0;
var entry_count: u64 = 0;
var entries: [512]Entry = undefined;
var entry_data: [16 * 1024]u8 = undefined;

const Entry = struct {
    start: u64,
    len: u16,
    header: abi.KLogEntryHeader,
};

pub fn create() !*KLog {
    const klog = try gpa.create(KLog);
    klog.* = .{
        .obj = .{
            .kind = .klog,
            .ref_count = .init(1),
        },
        .cur_id = 0,
    };
    return klog;
}

pub fn destroy(klog: *KLog) void {
    gpa.destroy(klog);
}

pub fn write(str: []const u8, header: abi.KLogEntryHeader) void {
    const capped = str[0..@min(str.len, abi.max_klog_msg)];
    const l = lock.lock();
    defer l.unlock();

    const new_start: u64 = if (entry_count != 0) blk: {
        const last_entry = entries[(first_entry + entry_count - 1) % entries.len];
        break :blk last_entry.start + last_entry.len;
    } else 0;
    const new_end = new_start + capped.len;

    if (entry_count == entries.len) {
        first_entry += 1;
        entry_count -= 1;
    }

    while (entry_count > 0) {
        const oldest = entries[first_entry % entries.len];
        const overlap = oldest.start + entry_data.len < new_end;
        if (!overlap) break;

        first_entry += 1;
        entry_count -= 1;
    }

    const entry: Entry = .{
        .start = new_start,
        .len = @intCast(capped.len),
        .header = header,
    };

    entries[(first_entry + entry_count) % entries.len] = entry;
    const full_upper = entry_data[new_start % entry_data.len ..];
    const upper = full_upper[0..@min(full_upper.len, capped.len)];
    @memcpy(upper, capped[0..upper.len]);

    const lower = entry_data[0 .. capped.len - upper.len];
    @memcpy(lower, capped[upper.len..]);

    entry_count += 1;
    printEntryAllBackends(entry);
}

var vga_text_term: Terminal = .{ .tg = &vga_text.tg };
var vga_text_writer = vga_text_term.writer(&.{});

var using_serial: bool = false;
var using_vga_text: bool = false;

pub fn preinit() !void {
    if (serial.init()) {
        using_serial = true;
        replay(first_entry + entry_count, .{ .writer = &serial.writer, .mode = .escape_codes });
    }
}

pub fn init() !void {
    if (boot_info.display == .vga_text) {
        using_vga_text = true;
        replay(first_entry + entry_count, .{ .writer = &vga_text_writer.w, .mode = .escape_codes });
    }
}

pub fn reclaim() void {
    lock.status.store(.unlocked, .monotonic);
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [abi.max_klog_msg]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    const abi_level: abi.KLogEntryHeader.Level = switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    const str_scope = if (scope == .default) "" else @tagName(scope);
    const capped_scope = str_scope[0..@min(str_scope.len, abi.max_klog_scope)];

    var header: abi.KLogEntryHeader = .{
        .scope = undefined,
        .flags = .{
            .level = abi_level,
            .truncated = false,
        },
    };

    @memcpy(header.scope[0..capped_scope.len], capped_scope);
    @memset(header.scope[capped_scope.len..], 0);

    writer.print(format, args) catch {
        header.flags.truncated = true;
    };

    write(writer.buffered(), header);
}

fn replay(up_to: u64, t: std.Io.Terminal) void {
    if (first_entry > 0) {
        t.writer.print("({} entries discarded)\n", .{first_entry}) catch {};
    }

    for (first_entry..up_to) |i| {
        const entry = entries[i % entries.len];
        printEntry(t, entry) catch {};
    }
}

fn printEntryAllBackends(entry: Entry) void {
    if (using_serial) printEntry(.{ .writer = &serial.writer, .mode = .escape_codes }, entry) catch {};
    if (using_vga_text) printEntry(.{ .writer = &vga_text_writer.w, .mode = .escape_codes }, entry) catch {};
}

fn printEntry(t: std.Io.Terminal, entry: Entry) !void {
    const scope = std.mem.sliceTo(@as([]const u8, &entry.header.scope), 0);

    t.setColor(.reset) catch {};
    t.setColor(switch (entry.header.flags.level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};

    t.setColor(.bold) catch {};
    try t.writer.writeAll(@tagName(entry.header.flags.level));
    t.setColor(.reset) catch {};
    t.setColor(.dim) catch {};
    t.setColor(.bold) catch {};
    if (scope.len != 0) try t.writer.print("({s})", .{scope});
    try t.writer.writeAll(": ");
    t.setColor(.reset) catch {};

    const full_upper = entry_data[entry.start % entry_data.len ..];
    const upper = full_upper[0..@min(full_upper.len, entry.len)];
    const lower = entry_data[0 .. entry.len - upper.len];

    try t.writer.writeAll(upper);
    try t.writer.writeAll(lower);
    try t.writer.writeAll("\n");
    if (entry.header.flags.truncated) {
        t.setColor(.reset) catch {};
        t.setColor(.dim) catch {};
        t.writer.print("(message truncated)\n", .{}) catch {};
    }
}
