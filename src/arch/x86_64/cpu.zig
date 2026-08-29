const arch = @import("x86_64.zig");
const scheduler = @import("../../scheduler.zig");
const mem = @import("../../memory.zig");

pub const ExtendedState = struct {
    fxsave: [512]u8 align(16),

    pub const zero: ExtendedState = .{ .fxsave = @splat(0) };
    pub inline fn save(state: *ExtendedState) void {
        asm volatile (
            \\fxsave (%[addr])
            :
            : [addr] "r" (&state.fxsave),
        );
    }

    pub inline fn load(state: *const ExtendedState) void {
        asm volatile (
            \\fxrstor (%[addr])
            :
            : [addr] "r" (&state.fxsave),
            : .{
              // zig fmt: off
              .xmm0  = true, .xmm1  = true, .xmm2  = true, .xmm3  = true,
              .xmm4  = true, .xmm5  = true, .xmm6  = true, .xmm7  = true,
              .xmm8  = true, .xmm9  = true, .xmm10 = true, .xmm11 = true,
              .xmm12 = true, .xmm13 = true, .xmm14 = true, .xmm15 = true,
              // zig fmt: on
            });
    }
};

pub const State = packed struct {
    cr3: u64,
    rbp: u64,

    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rsi: u64 = 0,
    rdi: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,

    int_code: u64 = 0,
    error_code: u64 = 0,

    rip: u64,
    cs: u64 = 0x8,
    flags: Flags,
    rsp: u64,
    ss: u64 = 0x10,

    pub fn restore(state: *align(1) const State) noreturn {
        asm volatile (
            \\ pop %rax
            \\ mov %cr3, %rbx
            \\ cmp %rax, %rbx
            \\ je 1f
            \\ mov %rax, %cr3
            \\ 1:
            \\
            \\ popq %rbp
            \\ popq %rax
            \\ popq %rbx
            \\ popq %rcx
            \\ popq %rdx
            \\ popq %rsi
            \\ popq %rdi
            \\ popq %r8
            \\ popq %r9
            \\ popq %r10
            \\ popq %r11
            \\ popq %r12
            \\ popq %r13
            \\ popq %r14
            \\ popq %r15
            \\
            \\ addq $0x10, %rsp
            \\ iretq
            :
            : [state] "{rsp}" (state),
        );

        unreachable;
    }

    pub fn fromKernelThreadSpawnInfo(info: scheduler.KernelThreadSpawnInfo) State {
        const stack_top = @intFromPtr(info.stack.ptr + info.stack.len);

        return .{
            .cr3 = @intFromPtr(info.phys_page_table),
            .rbp = stack_top,
            .rip = @intFromPtr(info.entry),
            .flags = .{ .IF = true },
            .rsp = stack_top,
            .rdi = info.arg,
        };
    }
};

pub const Flags = packed struct(u64) {
    CF: bool = false,
    _1: bool = true,
    PF: bool = false,
    _3: bool = false,
    AF: bool = false,
    _5: bool = false,
    ZF: bool = false,
    SF: bool = false,
    TF: bool = false,
    IF: bool = false,
    DF: bool = false,
    OF: bool = false,
    IOPL: u2 = 0,
    NT: bool = false,
    _15: bool = false,
    RF: bool = false,
    VM: bool = false,
    AC: bool = false,
    VIF: bool = false,
    VIP: bool = false,
    ID: bool = false,
    _22_63: u42 = 0,
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
    switch (@bitSizeOf(@TypeOf(data))) {
        8 => asm volatile ("outb %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{al}" (data),
        ),
        16 => asm volatile ("outw %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{ax}" (data),
        ),
        32 => asm volatile ("outl %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{eax}" (data),
        ),
        else => @compileError("bit size of type must be 8, 16, or 32. found " ++ @typeName(@TypeOf(data))),
    }
}

pub fn outb(port: u16, data: u8) void {
    out(port, data);
}

pub fn outw(port: u16, data: u8) void {
    out(port, data);
}

pub fn outl(port: u16, data: u8) void {
    out(port, data);
}

pub fn in(comptime T: type, port: u16) T {
    return switch (@bitSizeOf(T)) {
        8 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> T),
            : [port] "N{dx}" (port),
        ),
        16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> T),
            : [port] "N{dx}" (port),
        ),
        32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> T),
            : [port] "N{dx}" (port),
        ),
        else => @compileError("bit size of type must be 8, 16, or 32. found " ++ @typeName(T)),
    };
}

pub fn ioWait() void {
    out(0x80, @as(u8, 0));
}

pub fn readMsr(msr: u32) u64 {
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

pub fn writeMsr(msr: u32, value: u64) void {
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
