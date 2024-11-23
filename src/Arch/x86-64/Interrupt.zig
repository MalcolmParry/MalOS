const Arch = @import("Arch.zig");
const ISR = @import("../../ISR.zig");
const TTY = @import("../../TTY.zig");

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

pub fn Enable() void {
    asm volatile ("sti");
}

pub fn Disable() void {
    asm volatile ("cli");
}

fn SetupIDT(comptime index: u8, isrType: ISRType, dpl: u2, present: bool) void {
    const isrPtr = &GenerateInterruptStub(index);
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

export fn Handler(state: *Arch.CPUState) callconv(.SysV) void {
    TTY.Print("interrupt 0x{x}\n", .{state.intCode});

    if (state.intCode != 0x80) Arch.halt();
}

export fn CommonStub() callconv(.Naked) void {
    asm volatile (
        \\ pushq %r15
        \\ pushq %r14
        \\ pushq %r13
        \\ pushq %r12
        \\ pushq %r11
        \\ pushq %r10
        \\ pushq %r9
        \\ pushq %r8
        \\ pushq %rdi
        \\ pushq %rsi
        \\ pushq %rdx
        \\ pushq %rcx
        \\ pushq %rbx
        \\ pushq %rax
        \\ pushq %rbp
        \\ mov %cr3, %rax
        \\ pushq %rax
        \\
        \\ xor %ax, %ax
        \\ mov %ax, %ss
        \\ mov %ax, %ds
        \\ mov %ax, %es
        \\ mov %ax, %fs
        \\ mov %ax, %gs
        \\
        \\ movq %rsp, %rdi // 1st arg in rdi
        \\ andq $(~0xf), %rsp // 16 byte align
        \\ pushq $0
        \\ pushq %rdi
        \\ call Handler
        \\ popq %rsp
        \\
        \\ pop %rax
        \\ mov %cr3, %rbx
        \\ cmp %rax, %rbx
        \\ je same_cr3
        \\ mov %rax, %cr3
        \\ same_cr3:
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
    );
}

fn GenerateInterruptStub(comptime intNum: u8) fn () callconv(.Naked) void {
    return struct {
        fn func() callconv(.Naked) void {
            asm volatile (
                \\ cli
            );

            if (intNum != 8 and !(intNum >= 10 and intNum <= 14) and intNum != 17) {
                asm volatile (
                    \\ pushq $0
                );
            }

            asm volatile (
                \\ pushq %[intNum]
                \\ jmp CommonStub
                :
                : [intNum] "n" (@as(u64, intNum)),
            );
        }
    }.func;
}
