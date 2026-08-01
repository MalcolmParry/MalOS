const std = @import("std");
const arch = @import("arch.zig");
const mem = @import("memory.zig");
const Spinlock = @import("Spinlock.zig");

const Thread = struct {
    cpu_state: arch.arch.CPUState,
    ext_cpu_state: arch.arch.CpuExtendedState,

    pub const Slot = u32;
};

var thread_buffer: [32]Thread = undefined;
var threads: std.ArrayList(Thread) = .initBuffer(&thread_buffer);

var thread1_stack: [1024 * 16]u8 align(16) = undefined;
var thread2_stack: [1024 * 16]u8 align(16) = undefined;

pub fn spawnThread(rip: usize, stack_top: usize) void {
    threads.appendBounded(.{
        .ext_cpu_state = .zero,
        .cpu_state = .{
            .cr3 = @intFromPtr(&arch.paging.l4_table) - mem.kernel_virt_base,
            .rbp = stack_top,
            .rip = rip,
            .flags = .{ .IF = true },
            .rsp = stack_top,
        },
    }) catch @panic("too many threads");
}

var spinlock: Spinlock = .{};
fn thread1() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    std.log.info("thread 1", .{});

    arch.spinWait();
}

fn thread2() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    std.log.info("thread 2", .{});

    arch.spinWait();
}

pub fn init() void {
    spawnThread(@intFromPtr(&thread1), @intFromPtr(&thread1_stack) + thread1_stack.len - 8);
    spawnThread(@intFromPtr(&thread2), @intFromPtr(&thread2_stack) + thread2_stack.len - 8);
}

var current_tid: usize = 0;
pub fn saveThreadState(state: *const arch.arch.CPUState) void {
    const thread = &threads.items[current_tid];
    thread.cpu_state = state.*;
    thread.ext_cpu_state.save();
}

pub fn schedule() noreturn {
    current_tid = (current_tid + 1) % threads.items.len;
    const thread = &threads.items[current_tid];

    thread.ext_cpu_state.load();
    arch.interrupt.restoreCpuState(&thread.cpu_state);
}
