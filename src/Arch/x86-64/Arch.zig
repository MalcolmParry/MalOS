const std = @import("std");

pub const vga = @import("VGA.zig");
pub const interrupt = @import("Interrupt.zig");
pub const multiboot = @import("Multiboot.zig");
pub const paging = @import("Paging.zig");

pub const page_size = 1024 * 4;
pub const kernel_virt_base: u64 = 0xffff_ffff_c000_0000;

pub const boot_call_conv = std.builtin.CallingConvention{ .x86_64_sysv = .{ .incoming_stack_alignment = 16 } };
pub const initBootInfo = multiboot.initBootInfo;
pub const PageTable = paging.tables.L4;

pub const CPUState = packed struct {
    cr3: u64,
    rbp: u64,

    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,

    int_code: u64,
    error_code: u64,

    rip: u64,
    cs: u64,
    flags: u64,
    rsp: u64,
    ss: u64,
};

pub fn halt() void {
    asm volatile ("hlt");
}

pub fn spinWait() noreturn {
    while (true) {
        halt();
    }
}

pub fn int(x: u8) void {
    asm volatile ("int %[x]"
        :
        : [x] "N" (x),
    );
}

pub fn syscall() void {
    asm volatile ("int $0x80" ::: .{ .rax = true });
}

pub fn out(port: u16, data: anytype) void {
    switch (@TypeOf(data)) {
        u8 => asm volatile ("outb %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{al}" (data),
        ),
        u16 => asm volatile ("outw %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{ax}" (data),
        ),
        u32 => asm volatile ("outl %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{eax}" (data),
        ),
        else => @compileError("Invalid data type. Expected u8, u16, or u32, found " ++ @typeName(@TypeOf(data))),
    }
}

pub fn in(comptime Type: type, port: u16) Type {
    return switch (Type) {
        u8 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        u16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        u32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        else => @compileError("Invalid data type. Expected u8, u16, or u32, found " ++ @typeName(Type)),
    };
}

pub fn readMSR(msr: u32) u64 {
    var high: u32 = undefined;
    var low: u32 = undefined;

    asm volatile (
        \\rdmsr
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
        : .{});

    return @as(u64, high) << 32 | low;
}

pub fn writeMSR(msr: u32, value: u64) void {
    const high: u32 = @intCast(value >> 32);
    const low: u32 = @truncate(value);

    asm volatile (
        \\wrmsr
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
        : .{});
}
