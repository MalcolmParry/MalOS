const std = @import("std");
const abi = @import("abi");
const gpa = @import("../mem/gpa.zig").allocator;
const Spinlock = @import("../sync/Spinlock.zig");
const Object = @import("Object.zig");
const Terminal = @import("../tty/Terminal.zig");
const vga_text = @import("../drivers/x86/vga_text.zig");
const boot_info = @import("../boot_info.zig");
const serial = @import("../drivers/x86/serial.zig");
const Resource = @import("Resource.zig");
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
    scope: [abi.max_klog_scope]u8,
    flags: abi.KLogEntry.Flags,
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

pub const WriteInfo = struct {
    str: []const u8,
    scope: []const u8,
    level: abi.KLogEntry.Level,
    truncated: bool,
};

pub fn write(info: WriteInfo) void {
    const l = lock.lock();
    defer l.unlock();
    writeLocked(info);
}

pub fn writeLocked(info: WriteInfo) void {
    const str = info.str[0..@min(info.str.len, abi.max_klog_msg)];
    const scope = info.scope[0..@min(info.scope.len, abi.max_klog_scope)];

    const new_start: u64 = if (entry_count != 0) blk: {
        const last_entry = entries[(first_entry + entry_count - 1) % entries.len];
        break :blk last_entry.start + last_entry.len;
    } else 0;
    const new_end = new_start + str.len;

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

    var entry: Entry = .{
        .start = new_start,
        .len = @intCast(str.len),
        .scope = undefined,
        .flags = .{
            .level = info.level,
            .truncated = info.truncated or str.len != info.str.len,
        },
    };

    @memcpy(entry.scope[0..scope.len], scope);
    @memset(entry.scope[scope.len..], 0);

    entries[(first_entry + entry_count) % entries.len] = entry;
    const full_upper = entry_data[new_start % entry_data.len ..];
    const upper = full_upper[0..@min(full_upper.len, str.len)];
    @memcpy(upper, str[0..upper.len]);

    const lower = entry_data[0 .. str.len - upper.len];
    @memcpy(lower, str[upper.len..]);

    entry_count += 1;
    printEntryAllBackends(entry);
}

pub fn read(klog: *KLog, buffer: []u8, header: *abi.KLogEntry) !usize {
    const l = lock.lock();
    defer l.unlock();

    const id = if (klog.cur_id < first_entry) first_entry else klog.cur_id;
    if (id >= first_entry + entry_count) return error.IsEmpty;

    const entry = entries[id % entries.len];
    const to_read = @min(buffer.len, entry.len);

    const full_upper = entry_data[entry.start % entry_data.len ..];
    const upper = full_upper[0..@min(full_upper.len, to_read)];
    @memcpy(buffer[0..upper.len], upper);

    const lower = entry_data[0 .. to_read - upper.len];
    @memcpy(buffer[upper.len..][0..lower.len], lower);

    klog.cur_id = id + 1;
    header.* = .{
        .id = id,
        .scope = entry.scope,
        .flags = entry.flags,
    };

    return entry.len;
}

pub fn disableBackend(resource: *Resource) !usize {
    switch (resource.kind) {
        .klog_backend_serial => {
            const l = lock.lock();
            defer l.unlock();

            var buffer: [1024]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            writer.print("disabling serial backend at entry id {}", .{first_entry + entry_count}) catch unreachable;

            writeLocked(.{
                .str = writer.buffered(),
                .scope = "log",
                .level = .info,
                .truncated = false,
            });

            using_serial = false;
            return first_entry + entry_count;
        },
        else => return error.BadHandleKind,
    }
}

var vga_text_term: Terminal = .{ .tg = &vga_text.tg };
var vga_text_writer = vga_text_term.writer(&.{});

var serial_available: bool = false;
var using_serial: bool = false;
var using_vga_text: bool = false;

pub fn preinit() !void {
    if (serial.init()) {
        serial_available = true;
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
    using_serial = serial_available;
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [abi.max_klog_msg]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    var truncated: bool = false;
    writer.print(format, args) catch {
        truncated = true;
    };

    write(.{
        .str = writer.buffered(),
        .level = switch (level) {
            .err => .err,
            .warn => .warn,
            .info => .info,
            .debug => .debug,
        },
        .scope = if (scope == .default) "" else @tagName(scope),
        .truncated = truncated,
    });
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
    const scope = std.mem.sliceTo(@as([]const u8, &entry.scope), 0);

    t.setColor(.reset) catch {};
    t.setColor(switch (entry.flags.level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};

    t.setColor(.bold) catch {};
    try t.writer.writeAll(@tagName(entry.flags.level));
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
    if (entry.flags.truncated) {
        t.setColor(.reset) catch {};
        t.setColor(.dim) catch {};
        t.writer.print("(message truncated)\n", .{}) catch {};
    }
}
