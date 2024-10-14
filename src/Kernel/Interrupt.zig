const Core = @import("Core.zig");
const Console = @import("Console.zig");
const buildtin = @import("builtin");

const IDT = packed struct {
    offset1: u16,
    selector: u16,
    ist: u8,
    typeAttribs: u8,
    offset2: u16,
    offset3: u32,
    padding: u32,
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

fn SetupIDT(index: u8, isr: *const ISR, isrType: ISRType, present: bool) void {
    const intIsr: u64 = @intFromPtr(isr);
    const iPresent: u8 = if (present) 1 else 0;

    idts[index] = .{
        .offset1 = @truncate(intIsr),
        .offset2 = @truncate(intIsr >> 16),
        .offset3 = @truncate(intIsr >> 32),
        .selector = 8,
        .ist = 0,
        .typeAttribs = @intFromEnum(isrType) | (iPresent << 7),
        .padding = 0,
    };
}

pub fn Init() void {
    for (0..256) |i| {
        SetupIDT(@intCast(i), &ISRUnknown, .Interrupt, true);
    }

    SetupIDT(0x03, &ISR03, .Interrupt, true);
    SetupIDT(0x80, &ISR80, .Interrupt, true);

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
