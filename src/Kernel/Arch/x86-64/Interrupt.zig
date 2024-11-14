const Arch = @import("Arch.zig");
const ISR = @import("../../ISR.zig");

const IDT = packed struct {
    offset1: u16,
    selector: u16,
    ist: u8,
    gateType: u4,
    padding1: u1,
    dpl: u2,
    present: u1,
    offset2: u16,
    offset3: u32,
    padding2: u32,
};

const IDTR = packed struct {
    size: u16,
    base: *[256]IDT,
};

const ISRType = enum(u4) {
    Interrupt = 0b1110,
    Trap = 0b1111,
};

var idts: [256]IDT = undefined;
var idtr: IDTR = undefined;

fn SetupIDT(comptime index: u8, isrType: ISRType, dpl: u2, present: bool) void {
    const isrPtr = &ISRGenerator(index);
    const isr: u64 = @intFromPtr(isrPtr);

    idts[index] = .{
        .offset1 = @truncate(isr),
        .offset2 = @truncate(isr >> 16),
        .offset3 = @truncate(isr >> 32),
        .selector = 8,
        .ist = 0,
        .gateType = @intFromEnum(isrType),
        .dpl = dpl,
        .present = if (present) 1 else 0,
        .padding1 = 0,
        .padding2 = 0,
    };
}

pub fn Init() void {
    inline for (0..32) |i| {
        SetupIDT(i, .Trap, 0, true);
    }

    inline for (32..256) |i| {
        SetupIDT(i, .Interrupt, 0, true);
    }

    idtr.size = @sizeOf([256]IDT) - 1;
    idtr.base = &idts;

    asm volatile ("lidt (%%rax)"
        :
        : [idtr] "{rax}" (&idtr),
    );
}

export fn ISRWrapper() callconv(.Naked) void {
    _ = ISR.ISR;

    asm volatile (
        \\ push rsi
        \\ push rax
        \\ push rbx
        \\ push rcx
        \\ push rdx
        \\
        \\ cld
        \\ call ISR
        \\
        \\ pop rdx
        \\ pop rcx
        \\ pop rbx
        \\ pop rax
        \\ pop rsi
        \\ pop rdi
        \\ iretq
    );
}

export fn SyscallWrapper() callconv(.Naked) void {
    _ = ISR.Syscall;

    asm volatile (
        \\ push rdi
        \\ push rsi
        \\ push rbx
        \\ push rcx
        \\ push rdx
        \\
        \\ movq %rax, %rdi
        \\ movq %rbx, %rsi
        \\ call Syscall
        \\
        \\ pop rdx
        \\ pop rcx
        \\ pop rbx
        \\ pop rsi
        \\ pop rdi
        \\ iretq
    );
}

fn ISRGenerator(comptime intNum: u8) fn () callconv(.Naked) void {
    return struct {
        fn func() callconv(.Naked) void {
            asm volatile (
                \\ cli
                \\ push rdi
            );

            if (intNum == 0x80) {
                asm volatile ("jmp SyscallWrapper");
            } else {
                asm volatile (
                    \\ jmp ISRWrapper
                    :
                    : [intNum] "{rdi}" (intNum),
                );
            }
        }
    }.func;
}
