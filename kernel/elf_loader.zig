const std = @import("std");
const mem = @import("memory.zig");
const arch = @import("arch/arch.zig").current;
const Vmar = @import("object/Vmar.zig");
const Vmo = @import("object/Vmo.zig");

const Result = struct {
    entry: usize,
};

pub fn load(vmar: *Vmar, elf: []const u8) !Result {
    var reader: std.Io.Reader = .fixed(elf);

    const header = try std.elf.Header.read(&reader);
    if (!header.is_64) return error.NotSupported;
    if (header.machine != .X86_64) return error.NotSupported;
    if (header.type != .EXEC) return error.NotSupported;
    if (header.entry >= arch.paging.max_user_addr) return error.BadElf;

    const vmar_l = vmar.lock.lock();
    defer vmar_l.unlock();

    for (0..header.phnum) |i| {
        reader.seek = header.phoff + i * header.phentsize;
        const ph = try reader.takeStruct(std.elf.Elf64.Phdr, header.endian);
        if (ph.type != .LOAD) continue;
        if (ph.filesz > ph.memsz) return error.BadElf;
        if (ph.memsz == 0) continue;
        if (ph.vaddr < mem.page_size) return error.NotSupported;
        if (ph.flags.W and ph.flags.X) return error.NotSupported;

        const end = std.math.add(u64, ph.vaddr, ph.memsz) catch return error.BadElf;
        if (end > arch.paging.max_user_addr) return error.BadElf;

        const first_page = ph.vaddr / mem.page_size;
        const offset_from_page = ph.vaddr % mem.page_size;
        const end_page = (end + mem.page_size - 1) / mem.page_size;
        const page_count = end_page - first_page;

        const vmo = try Vmo.create(ph.memsz + offset_from_page);
        defer vmo.obj.release();

        try vmo.write(offset_from_page, elf[ph.offset..][0..ph.filesz]);
        try vmo.commitLocked(0, page_count);

        try vmar.mapLocked(vmo, 0, first_page, page_count, .{
            .w = ph.flags.W,
            .x = ph.flags.X,
        });
    }

    return .{ .entry = header.entry };
}
