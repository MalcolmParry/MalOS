const Ptr = packed struct {
    size_bytes: u16,
    ptr: u64,
};

const Tss = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u48 = 0,
    iomap_base: u16 = @sizeOf(Tss),
};

var gdt: [7]Desc = undefined;
var tss: Tss = undefined;
const Desc = u64;
const executable_bit: Desc = 1 << 43;
const code_or_data_bit: Desc = 1 << 44;
const present_bit: Desc = 1 << 47;
const long_mode_bit: Desc = 1 << 53;
const read_write_bit: Desc = 1 << 41;
const dpl3_bits: Desc = 3 << 45;

pub fn init() void {
    const tss_base: u64 = @intFromPtr(&tss);
    const tss_limit: u64 = @sizeOf(Tss) - 1;

    gdt = .{
        // null desc
        0,
        // kernel code desc
        executable_bit | code_or_data_bit | present_bit | long_mode_bit | read_write_bit,
        // kernel data desc
        present_bit | code_or_data_bit | read_write_bit,
        // user code desc
        executable_bit | code_or_data_bit | present_bit | long_mode_bit | read_write_bit | dpl3_bits,
        // user data desc
        present_bit | code_or_data_bit | read_write_bit | dpl3_bits,
        // task state segment
        (tss_limit & 0xffff) |
            ((tss_base & 0xffff) << 16) |
            (((tss_base >> 16) & 0xff) << 32) |
            present_bit |
            (0x9 << 40) |
            (((tss_limit >> 16) & 0xf) << 48) |
            (((tss_base >> 24) & 0xff) << 56),
        (tss_base >> 32) & 0xffff_ffff,
    };

    tss = .{};

    const gdtr: Ptr = .{
        .ptr = @intFromPtr(&gdt),
        .size_bytes = @sizeOf(Desc) * gdt.len - 1,
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

    asm volatile (
        \\mov $0x28, %%ax
        \\ltr %%ax
        ::: .{ .ax = true });
}
