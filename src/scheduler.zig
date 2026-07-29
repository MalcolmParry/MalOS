const std = @import("std");
const arch = @import("arch.zig");
const mem = @import("memory.zig");

const Thread = struct {
    cpu_state: arch.arch.CPUState,
};

var thread1_stack: [1024 * 16]u8 align(16) = undefined;
var thread2_stack: [1024 * 16]u8 align(16) = undefined;

pub var threads: [2]Thread = undefined;

fn thread1() noreturn {
    std.log.info("thread 1\n", .{});

    arch.spinWait();
}

fn thread2() noreturn {
    std.log.info("thread 2\n", .{});

    arch.spinWait();
}

var current_tid: usize = 0;

pub fn init() void {
    threads = .{
        .{ .cpu_state = .{
            .cr3 = @intFromPtr(&arch.paging.l4_table) - mem.kernel_virt_base,
            .rbp = @intFromPtr(&thread1_stack) + thread1_stack.len - 8,

            .rax = 0,
            .rbx = 0,
            .rcx = 0,
            .rdx = 0,
            .rsi = 0,
            .rdi = 0,
            .r8 = 0,
            .r9 = 0,
            .r10 = 0,
            .r11 = 0,
            .r12 = 0,
            .r13 = 0,
            .r14 = 0,
            .r15 = 0,

            .int_code = 0,
            .error_code = 0,

            .rip = @intFromPtr(&thread1),
            .cs = 8,
            .flags = .{ .IF = true },
            .rsp = @intFromPtr(&thread1_stack) + thread1_stack.len - 8,
            .ss = 0,
        } },
        .{ .cpu_state = .{
            .cr3 = @intFromPtr(&arch.paging.l4_table) - mem.kernel_virt_base,
            .rbp = @intFromPtr(&thread2_stack) + thread2_stack.len - 8,

            .rax = 0,
            .rbx = 0,
            .rcx = 0,
            .rdx = 0,
            .rsi = 0,
            .rdi = 0,
            .r8 = 0,
            .r9 = 0,
            .r10 = 0,
            .r11 = 0,
            .r12 = 0,
            .r13 = 0,
            .r14 = 0,
            .r15 = 0,

            .int_code = 0,
            .error_code = 0,

            .rip = @intFromPtr(&thread2),
            .cs = 8,
            .flags = .{ .IF = true },
            .rsp = @intFromPtr(&thread2_stack) + thread2_stack.len - 8,
            .ss = 0,
        } },
    };
}

pub fn schedule(state: *const arch.arch.CPUState) noreturn {
    const last_tid = current_tid;
    current_tid = (current_tid + 1) % threads.len;

    threads[last_tid].cpu_state = state.*;
    arch.interrupt.restoreCpuState(&threads[current_tid].cpu_state);
}
