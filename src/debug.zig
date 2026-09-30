const std = @import("std");
const options = @import("options");
const arch = @import("arch/arch.zig").current;
const log = @import("log.zig");
const mem = @import("memory.zig");
const builtin = @import("builtin");
const gpa = @import("heap/gpa.zig");
const BootInfo = @import("BootInfo.zig");

var kernel_range: ?[]u8 = null;
var dwarf: std.debug.Dwarf = .{};
var maybe_src_tar: ?[]align(mem.page_size) const u8 = null;

pub fn init(boot_info: *const BootInfo) void {
    kernel_range = @as([*]u8, @ptrFromInt(@intFromPtr(boot_info.kernel_phys_range.ptr) + mem.kernel_virt_base))[0..boot_info.kernel_phys_range.len];

    for (boot_info.modules()) |module| {
        if (!std.mem.eql(u8, module.name(), "kernel_src_tar")) continue;
        maybe_src_tar = module.data;
    }

    for (0..@typeInfo(std.debug.Dwarf.Section.Id).@"enum".fields.len) |i| {
        const section = boot_info.elf_sections.values[i] orelse continue;
        dwarf.sections[i] = .{
            .data = section.data,
            .owned = false,
        };
    }

    dwarf.open(getDebugInfoAllocator(), builtin.cpu.arch.endian()) catch @panic("failed to init dwarf");
}

pub fn panic(str: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);

    arch.interrupt.disable();
    log.spinlock.status.store(.unlocked, .monotonic);

    std.debug.writeCurrentStackTrace(.{
        .first_address = ret_addr orelse @frameAddress(),
        .allow_unsafe_unwind = true,
    }, log.term) catch {};

    std.log.err("Kernel Panic: {s}", .{str});
    arch.spinWait();
}

pub fn dumpError(err: anytype) void {
    if (@errorReturnTrace()) |trace|
        std.debug.writeErrorReturnTrace(trace, log.term) catch {};

    log.writer.print(" --// CAUGHT AT \\\\--\n", .{}) catch {};

    std.debug.writeCurrentStackTrace(.{
        .allow_unsafe_unwind = true,
        .first_address = @returnAddress(),
    }, log.term) catch {};

    std.log.err("Error: {}", .{err});
}

pub fn dumpErrorAndPanic(err: anytype) noreturn {
    arch.interrupt.disable();
    if (@errorReturnTrace()) |trace|
        std.debug.writeErrorReturnTrace(trace, log.term) catch {};

    log.writer.print(" --// CAUGHT AT \\\\--\n", .{}) catch {};

    std.debug.writeCurrentStackTrace(.{
        .allow_unsafe_unwind = true,
        .first_address = @returnAddress(),
    }, log.term) catch {};

    std.log.err("Kernel Panic: {}", .{err});
    arch.spinWait();
}

pub fn getDebugInfoAllocator() std.mem.Allocator {
    return gpa.allocator;
}

const UstarNode = extern struct {
    name: [100]u8,
    mode: [8]u8,
    owner: [8]u8,
    group: [8]u8,
    size_oct_str: [12]u8,
    mtime_oct_str: [12]u8,
    checksum: [8]u8,
    type: u8,
    link_name: [100]u8,
    magic: [6]u8,
    version: [2]u8,
    owner_name: [32]u8,
    group_name: [32]u8,
    dev_major: [8]u8,
    dev_minor: [8]u8,
    name_prefix: [155]u8,
    pad: [12]u8,

    fn readOctal(T: type, str: []const u8) T {
        var val: T = 0;
        for (str) |c| switch (c) {
            '0'...'7' => {
                val *= 8;
                val += c - '0';
            },
            else => continue,
        };
        return val;
    }

    fn size(node: *const UstarNode) usize {
        return readOctal(usize, &node.size_oct_str);
    }

    fn nameEql(node: *const UstarNode, other: []const u8) bool {
        return std.mem.eql(u8, other, node.name[0..other.len]);
    }

    comptime {
        std.debug.assert(@sizeOf(UstarNode) == 512);
    }
};

pub fn printLineFromFile(io: std.Io, writer: *std.Io.Writer, src_loc: std.debug.SourceLocation) !void {
    _ = io;
    const src_tar = maybe_src_tar orelse return error.NoSource;
    const tar_end = src_tar.ptr + src_tar.len;
    const target_name = if (src_loc.file_name.len > options.build_root.len + 1)
        src_loc.file_name[options.build_root.len + 1 ..]
    else {
        try writer.print("file not found\n", .{});
        return error.NoFile;
    };

    var node: *const UstarNode = @ptrCast(src_tar.ptr);
    while (@intFromPtr(node) < @intFromPtr(tar_end)) : ({
        node = @ptrCast(@as([*]const UstarNode, @ptrCast(node)) + (node.size() + 511) / 512 + 1);
    }) {
        if (!std.mem.eql(u8, &node.magic, "ustar\x00")) break;
        if (!node.nameEql(target_name)) continue;

        const data = @as([*]const u8, @ptrFromInt(@intFromPtr(node) + 512))[0..node.size()];
        if (@intFromPtr(data.ptr + data.len) > @intFromPtr(tar_end)) return error.BadUstar;
        var line_iter = std.mem.splitScalar(u8, data, '\n');
        var i: usize = 1;
        while (line_iter.next()) |line| : (i += 1) {
            if (i != src_loc.line) continue;

            try writer.print("{s}\n", .{line});
            return;
        }

        try writer.print("line not found\n", .{});
        return error.NoLine;
    }

    try writer.print("file not found\n", .{});
    return error.NoFile;
}

pub const SelfInfo = struct {
    pub const init: SelfInfo = .{};
    pub const can_unwind = false;

    const Error = std.debug.SelfInfoError;

    pub fn getSymbols(
        si: *SelfInfo,
        io: std.Io,
        symbol_allocator: std.mem.Allocator,
        text_arena: std.mem.Allocator,
        address: usize,
        resolve_inline_callers: bool,
        symbols: *std.ArrayList(std.debug.Symbol),
    ) Error!void {
        _ = si;
        _ = io;

        return dwarf.getSymbols(
            symbol_allocator,
            text_arena,
            builtin.cpu.arch.endian(),
            address,
            resolve_inline_callers,
            symbols,
        );
    }

    pub fn getModuleName(si: *SelfInfo, io: std.Io, address: usize) Error![]const u8 {
        _ = .{ si, io };
        if (kernel_range == null or address < @intFromPtr(kernel_range.?.ptr) or address >= @intFromPtr(kernel_range.?.ptr + kernel_range.?.len))
            return error.MissingDebugInfo;

        return "malos";
    }
};
