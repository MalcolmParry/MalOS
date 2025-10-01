const std = @import("std");

pub const VGA = @import("VGA.zig");
pub const Interrupt = @import("Interrupt.zig");
pub const Multiboot = @import("Multiboot.zig");

pub const pageSize = 1024 * 4;
pub const kernelVirtBase: u64 = 0xffff_ffff_c000_0000;

pub const BootCallConv = std.builtin.CallingConvention{ .x86_64_sysv = .{ .incoming_stack_alignment = 16 } };
pub const InitBootInfo = Multiboot.InitBootInfo;

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

    intCode: u64,
    errorCode: u64,

    rip: u64,
    cs: u64,
    flags: u64,
    rsp: u64,
    ss: u64,
};

pub fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
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
