const std = @import("std");
const builtin = @import("builtin");
const mem = @import("../../memory.zig");
const arch = @import("arch.zig");
const isr = @import("../../isr.zig");
const pic = @import("pic.zig");
const scheduler = @import("../../scheduler.zig");
const panic = @import("../../panic.zig");

const IDT = packed struct {
    // part of the ISR ptr
    offset1: u16,
    /// code segment to use
    selector: u16 = 8,
    ist: u3,
    padding3: u5 = 0,
    gate_type: GateType,
    padding1: u1 = 0,
    /// ring 0 for kernel, 3 for userspace
    dpl: u2,
    present: bool,
    offset2: u16,
    offset3: u32,
    padding2: u32 = 0,
};

const IDTR = extern struct {
    size: u16,
    base: *[256]IDT align(2),
};

const GateType = enum(u4) {
    interrupt = 0b1110,
    trap = 0b1111,
    task = 0b0101,
};

var idts: [256]IDT = undefined;
var idtr: IDTR = undefined;

pub fn enable() void {
    if (builtin.is_test) return;
    asm volatile ("sti");
}

pub fn disable() void {
    if (builtin.is_test) return;
    asm volatile ("cli");
}

pub fn popDisable() bool {
    if (builtin.is_test) return false;

    const rflags = asm volatile (
        \\ pushfq
        \\ cli
        \\ popq %[flags]
        : [flags] "=r" (-> arch.RFlags),
    );

    return rflags.IF;
}

pub fn set(enabled: bool) void {
    if (enabled) {
        enable();
    } else {
        disable();
    }
}

fn setupIDT(index: u8, isr_type: GateType, dpl: u2, present: bool) void {
    const isr_ptr = stub_table[index];
    const isr_int: u64 = @intFromPtr(isr_ptr);

    idts[index] = .{
        .offset1 = @truncate(isr_int),
        .offset2 = @truncate(isr_int >> 16),
        .offset3 = @truncate(isr_int >> 32),
        .ist = 0,
        .gate_type = isr_type,
        .dpl = dpl,
        .present = present,
    };
}

pub fn init() void {
    for (0..256) |i| {
        setupIDT(@intCast(i), .interrupt, 0, true);
    }

    idtr.size = @sizeOf([256]IDT) - 1;
    idtr.base = &idts;

    asm volatile ("lidt (%%rax)"
        :
        : [idtr] "{rax}" (&idtr),
    );

    pic.init();
}

const PageFaultFlags = packed struct(u64) {
    present: bool,
    write_fault: bool,
    user_mode_fault: bool,
    reserved: u1,
    instruction_fetch_fault: bool,
    unused: u59,
};

fn handler(state: *align(1) arch.CPUState) callconv(.{ .x86_64_sysv = .{ .incoming_stack_alignment = 1 } }) noreturn {
    scheduler.saveThreadState(state);

    switch (state.int_code) {
        0x20 => {
            pic.eoi();
            scheduler.schedule();
        },
        0xe => {
            const flags: PageFaultFlags = @bitCast(state.error_code);
            const cr2: usize = asm volatile (
                \\mov %%cr2, %[out]
                : [out] "=r" (-> usize),
            );

            std.log.err("page fault\n{}", .{flags});
            panic.getSymbolTable();
            panic.writeTraceAddr(cr2);

            const indices = arch.paging.tables.getIndicesFromVirtAddr(cr2);
            std.log.err("page table indices: {any}", .{indices});

            const l4: *arch.paging.tables.L4 = @ptrFromInt(state.cr3 + arch.kernel_virt_base);
            if (l4.tables[indices[3]]) |l3| {
                std.log.err("l3 addr 0x{x}", .{@intFromPtr(l3)});

                if (l3.tables[indices[2]]) |l2| {
                    std.log.err("l2 addr 0x{x}", .{@intFromPtr(l2)});

                    if (l2.tables[indices[1]]) |l1| {
                        std.log.err("l1 addr 0x{x}, {x}", .{ @intFromPtr(l1), l2.entries[indices[1]].address });

                        const entry = l1.entries[indices[0]];
                        std.log.err("present: {}", .{entry.present});
                        std.log.err("phys addr: 0x{x}", .{@as(usize, entry.address) * 4096});
                    }
                }
            }

            arch.spinWait();
        },
        0x80 => {
            std.log.info("syscall", .{});

            pic.eoi();
            scheduler.schedule();
        },
        else => {
            std.log.info("interrupt 0x{x}", .{state.int_code});
            arch.spinWait();
        },
    }
}

fn commonStub() callconv(.naked) void {
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
        \\ xor %ebp, %ebp
        \\ movq %rsp, %rdi // 1st arg in rdi
        \\ jmp handler
    );
}

comptime {
    if (!builtin.is_test) {
        @export(&commonStub, .{ .name = "commonStub" });
        @export(&handler, .{ .name = "handler" });
    }
}

const Stub = fn () callconv(.naked) void;
const stub_table = blk: {
    var result: [256]*const Stub = undefined;

    for (0..256) |i| {
        result[i] = &generateInterruptStub(i);
    }

    break :blk result;
};

fn generateInterruptStub(comptime int_num: u8) Stub {
    return struct {
        fn func() callconv(.naked) void {
            asm volatile (
                \\ cli
            );

            if (int_num != 8 and !(int_num >= 10 and int_num <= 14) and int_num != 17 and int_num != 21) {
                asm volatile (
                    \\ pushq $0
                );
            }

            asm volatile (
                \\ pushq %[int_num]
                \\ jmp commonStub
                :
                : [int_num] "n" (@as(u64, int_num)),
            );
        }
    }.func;
}
