const std = @import("std");
const mem = @import("memory.zig");
const arch = @import("arch/arch.zig").current;
const vfs = @import("fs/vfs/vfs.zig");
const AddressSpace = @import("task/AddressSpace.zig");

const Result = struct {
    entry: usize,
};

/// as must be loaded
pub fn load(as: *AddressSpace, elf: []const u8) !Result {
    var reader: std.Io.Reader = .fixed(elf);

    const header = try std.elf.Header.read(&reader);
    if (!header.is_64) return error.NotSupported;
    if (header.machine != .X86_64) return error.NotSupported;
    if (header.type != .EXEC) return error.NotSupported;
    if (header.entry > arch.paging.max_user_addr) return error.BadElf;

    for (0..header.phnum) |i| {
        reader.seek = header.phoff + i * header.phentsize;
        const ph = try reader.takeStruct(std.elf.Elf64.Phdr, header.endian);
        if (ph.type != .LOAD) continue;
        if (ph.filesz > ph.memsz) return error.BadElf;
        if (ph.memsz == 0) continue;
        if (ph.vaddr < mem.page_size) return error.NotSupported;

        const end = std.math.add(u64, ph.vaddr, ph.memsz) catch return error.BadElf;
        if (end > arch.paging.max_user_addr) return error.BadElf;

        const first_page = std.mem.alignBackward(u64, ph.vaddr, mem.page_size) / mem.page_size;
        const end_page = std.mem.alignForward(u64, end, mem.page_size) / mem.page_size;
        const page_count = end_page - first_page;

        try as.map(first_page, page_count, .{
            .alloc = true,
            .w = true,
            .x = true,
        });

        const mapping = @as([*]u8, @ptrFromInt(ph.vaddr))[0..ph.filesz];
        @memcpy(mapping, elf[ph.offset..][0..mapping.len]);

        // TODO: remap as with proper permissions
    }

    return .{ .entry = header.entry };
}
