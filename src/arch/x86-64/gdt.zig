const GDT = struct {
    const Ptr = packed struct {
        size_bytes: u16,
        ptr: u64,
    };

    const Desc = u64;
    const executable_bit: Desc = 1 << 43;
    const code_or_data_bit: Desc = 1 << 44;
    const present_bit: Desc = 1 << 47;
    const long_mode_bit: Desc = 1 << 53;
    const read_write_bit: Desc = 1 << 41;
    const dpl3_bits: Desc = 3 << 45;

    const descriptors: [3]Desc = .{
        // null desc
        0,
        // kernel code desc
        executable_bit | code_or_data_bit | present_bit | long_mode_bit | read_write_bit,
        // kernel data desc
        present_bit | code_or_data_bit | read_write_bit,
    };
};

pub fn init() void {
    const gdtr: GDT.Ptr = .{
        .ptr = @intFromPtr(&GDT.descriptors),
        .size_bytes = @sizeOf(GDT.Desc) * GDT.descriptors.len - 1,
    };

    asm volatile (
        \\lgdt (%[addr])
        :
        : [addr] "r" (&gdtr),
        : .{ .memory = true });

    asm volatile (
        \\push $0x08
        \\lea 1f(%%rip), %%rax
        \\push %%rax
        \\lretq
        \\1:
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        ::: .{ .rax = true, .memory = true });
}
