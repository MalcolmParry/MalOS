const std = @import("std");

/// Symbol as it appears in symbol_table module
/// Must remain in sync with src/panic.zig
/// Symbols in the module will be sorted by address
pub const Symbol = extern struct {
    addr: u64,
    /// offset into symbol_names module
    name_offset: u32,
    name_len: u32,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();

    var arg_iter = try init.minimal.args.iterateAllocator(gpa);
    defer arg_iter.deinit();

    _ = arg_iter.next();
    const kernel_path = arg_iter.next().?;
    const sym_tab_path = arg_iter.next().?;
    const sym_name_path = arg_iter.next().?;

    var buffer: [4096]u8 = undefined;
    const kernel = try cwd.openFile(io, kernel_path, .{});
    defer kernel.close(io);

    var reader = kernel.reader(io, &buffer);
    const header = try std.elf.Header.read(&reader.interface);
    if (!header.is_64) return error.Failed;
    const sections = try gpa.alloc(std.elf.Elf64_Shdr, header.shnum);
    defer gpa.free(sections);

    var iter = header.iterateSectionHeaders(&reader);
    while (try iter.next()) |shdr| {
        sections[iter.index - 1] = shdr;
    }

    var own_syms = std.ArrayList(Symbol).empty;
    defer own_syms.deinit(gpa);

    var elf_syms: std.ArrayList(std.elf.Elf64.Sym) = .empty;
    defer elf_syms.deinit(gpa);

    const sym_name_file = try cwd.createFile(io, sym_name_path, .{ .truncate = true });
    defer sym_name_file.close(io);

    var sym_name_buffer: [4096]u8 = undefined;
    var sym_name_writer = sym_name_file.writer(io, &sym_name_buffer);
    var name_offset: usize = 0;

    for (sections) |section| {
        if (section.sh_type != std.elf.SHT_SYMTAB) continue;
        const strtab_header = &sections[section.sh_link];
        const strtab_offset = strtab_header.sh_offset;

        if (section.sh_entsize != @sizeOf(std.elf.Elf64.Sym)) return error.Failed;
        const symbol_count = section.sh_size / @sizeOf(std.elf.Elf64.Sym);

        try elf_syms.resize(gpa, symbol_count);
        try reader.seekTo(section.sh_offset);
        try reader.interface.readSliceEndian(std.elf.Elf64.Sym, elf_syms.items, .little);

        try own_syms.ensureUnusedCapacity(gpa, symbol_count);
        for (elf_syms.items) |elf_sym| {
            if (elf_sym.shndx == std.elf.SHN_UNDEF) continue;
            switch (elf_sym.info.type) {
                .FUNC, .OBJECT => {},
                else => continue,
            }

            try reader.seekTo(strtab_offset + elf_sym.name);
            const name = try reader.interface.takeDelimiter(0) orelse continue;

            own_syms.appendAssumeCapacity(.{
                .addr = elf_sym.value,
                .name_offset = @intCast(name_offset),
                .name_len = @intCast(name.len),
            });

            try sym_name_writer.interface.writeAll(name);
            name_offset += name.len;
        }
    }

    std.mem.sort(Symbol, own_syms.items, {}, struct {
        fn lessThan(_: void, lhs: Symbol, rhs: Symbol) bool {
            return lhs.addr < rhs.addr;
        }
    }.lessThan);

    {
        const sym_tab_file = try cwd.createFile(io, sym_tab_path, .{ .truncate = true });
        defer sym_tab_file.close(io);
        try sym_tab_file.writePositionalAll(io, std.mem.sliceAsBytes(own_syms.items), 0);
    }

    try sym_name_writer.flush();
}
