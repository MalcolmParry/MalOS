const Core = @import("Core.zig");
const Console = @import("Console.zig");

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

const ISR: type = fn () callconv(.Interrupt) void;

var idts: [256]IDT = undefined;
var idtr: IDTR = undefined;

fn SetupIDT(index: u8, isr: *const ISR, isrType: ISRType, dpl: u2, present: bool) void {
    const intIsr: u64 = @intFromPtr(isr);

    idts[index] = .{
        .offset1 = @truncate(intIsr),
        .offset2 = @truncate(intIsr >> 16),
        .offset3 = @truncate(intIsr >> 32),
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
    for (0..256) |i| {
        SetupIDT(@intCast(i), &ISRUnknown, .Interrupt, 0, true);
    }

    SetupIDT(0x03, &ISR03, .Interrupt, 0, true);
    SetupIDT(0x80, &ISR80, .Interrupt, 0, true);

    idtr.size = @sizeOf([256]IDT) - 1;
    idtr.base = &idts;

    asm volatile ("lidt (%%rax)"
        :
        : [idtr] "{rax}" (&idtr),
    );
}

fn ISRUnknown() callconv(.Interrupt) void {
    Console.Print("da fuq\n");
    Disable();
    Core.hlt();
}

fn ISR03() callconv(.Interrupt) void {
    Console.Print("big pnaic\n");
    Disable();
    Core.hlt();
}

fn ISR80() callconv(.Interrupt) void {
    Console.Print("Hello Interrupts!\n");
}

pub fn Enable() void {
    asm volatile ("sti");
}

pub fn Disable() void {
    asm volatile ("cli");
}
