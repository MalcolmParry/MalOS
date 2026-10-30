const std = @import("std");
const options = @import("options");
const arch = @import("arch/arch.zig").current;
const log = @import("log.zig");
const mem = @import("memory.zig");
const builtin = @import("builtin");
const gpa = @import("heap/gpa.zig");
const BootInfo = @import("BootInfo.zig");
const ustar = @import("shared").ustar;

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
    std.log.err("Kernel Panic: {s}", .{str});

    std.debug.writeCurrentStackTrace(.{
        .first_address = ret_addr orelse @returnAddress(),
        .allow_unsafe_unwind = true,
    }, log.term) catch {};

    arch.spinWait();
}

pub fn dumpError(err: anytype) void {
    std.log.err("Error: {}", .{err});

    if (@errorReturnTrace()) |trace|
        std.debug.writeErrorReturnTrace(trace, log.term) catch {};

    log.writer.print(" --// CAUGHT AT \\\\--\n", .{}) catch {};

    std.debug.writeCurrentStackTrace(.{
        .allow_unsafe_unwind = true,
        .first_address = @returnAddress(),
    }, log.term) catch {};
}

pub fn dumpErrorAndPanic(err: anytype) noreturn {
    @branchHint(.cold);

    arch.interrupt.disable();
    log.spinlock.status.store(.unlocked, .monotonic);
    std.log.err("Kernel Panic: {}", .{err});

    if (@errorReturnTrace()) |trace|
        std.debug.writeErrorReturnTrace(trace, log.term) catch {};

    log.writer.print(" --// CAUGHT AT \\\\--\n", .{}) catch {};

    std.debug.writeCurrentStackTrace(.{
        .allow_unsafe_unwind = true,
        .first_address = @returnAddress(),
    }, log.term) catch {};

    arch.spinWait();
}

pub fn getDebugInfoAllocator() std.mem.Allocator {
    return gpa.allocator;
}

pub fn printLineFromFile(_: std.Io, writer: *std.Io.Writer, src_loc: std.debug.SourceLocation) !void {
    const src_tar = maybe_src_tar orelse return error.NoSource;
    const src_file = try ustar.lookup(src_tar, src_loc.file_name) orelse {
        try writer.print("file not found\n", .{});
        return error.NoFile;
    };

    var line_iter = std.mem.splitScalar(u8, src_file, '\n');
    var i: usize = 1;
    while (line_iter.next()) |line| : (i += 1) {
        if (i != src_loc.line) continue;

        try writer.print("{s}\n", .{line});
        return;
    }

    try writer.print("line not found\n", .{});
    return error.NoLine;
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

        try dwarf.getSymbols(
            symbol_allocator,
            text_arena,
            builtin.cpu.arch.endian(),
            address,
            resolve_inline_callers,
            symbols,
        );

        const prefix = options.build_root ++ "/";
        for (symbols.items) |*sym| {
            if (sym.source_location == null) continue;
            const src_loc = &sym.source_location.?;
            if (!std.mem.startsWith(u8, src_loc.file_name, prefix)) continue;
            src_loc.file_name = src_loc.file_name[prefix.len..];
        }
    }

    pub fn getModuleName(si: *SelfInfo, io: std.Io, address: usize) Error![]const u8 {
        _ = .{ si, io };
        if (kernel_range == null or address < @intFromPtr(kernel_range.?.ptr) or address >= @intFromPtr(kernel_range.?.ptr + kernel_range.?.len))
            return error.MissingDebugInfo;

        return "malos";
    }
};
