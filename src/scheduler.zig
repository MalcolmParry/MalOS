const std = @import("std");
const arch = @import("arch.zig");
const mem = @import("memory.zig");
const Spinlock = @import("Spinlock.zig");
const PageAllocator = @import("heap/PageAllocator.zig");

const Thread = struct {
    cpu_state: arch.arch.CPUState,
    ext_cpu_state: arch.arch.CpuExtendedState,

    pub const Slot = u32;
};

pub const ThreadEntry = fn (arg: u64) callconv(.{ .x86_64_sysv = .{ .incoming_stack_alignment = 8 } }) noreturn;
pub const KernelThreadSpawnInfo = struct {
    entry: ?*const ThreadEntry,
    stack: []u8,
    phys_page_table: *mem.Phys(arch.paging.Table),
    arg: u64,
};

var thread_buffer: [32]Thread = undefined;
var threads: std.ArrayList(Thread) = .initBuffer(&thread_buffer);

pub fn spawnKernelThread(entry: *const ThreadEntry, arg: u64) void {
    const stack_size = 16 * 1024;
    const stack = PageAllocator.global.alloc(stack_size / mem.page_size, .{
        .cache_mode = .full,
        .global = true,
        .executable = false,
        .user = false,
        .writable = true,
    }) catch @panic("can't allocate stack for kernel thread");

    threads.appendBounded(.{
        .ext_cpu_state = .zero,
        .cpu_state = .fromKernelThreadSpawnInfo(.{
            .entry = entry,
            .stack = std.mem.sliceAsBytes(stack),
            .phys_page_table = @ptrFromInt(@intFromPtr(&arch.paging.l4_table) - mem.kernel_virt_base),
            .arg = arg,
        }),
    }) catch @panic("too many threads");
}

var in_buffer: [8]u8 = undefined;
var in_head: std.atomic.Value(u64) = .init(0);
var in_tail: std.atomic.Value(u64) = .init(0);

fn thread1(_: u64) callconv(.{ .x86_64_sysv = .{ .incoming_stack_alignment = 8 } }) noreturn {
    std.log.info("thread 1", .{});

    while (true) {
        const byte = arch.serial.read();
        while (in_head.load(.monotonic) >= in_tail.load(.monotonic) + in_buffer.len) {
            std.atomic.spinLoopHint();
        }

        in_buffer[in_head.load(.monotonic) % in_buffer.len] = byte;
        _ = in_head.fetchAdd(1, .release);
    }
}

fn thread2(_: u64) callconv(.{ .x86_64_sysv = .{ .incoming_stack_alignment = 8 } }) noreturn {
    std.log.info("thread 2", .{});

    while (true) {
        while (in_head.load(.monotonic) == in_tail.load(.monotonic)) {
            std.atomic.spinLoopHint();
        }

        const tail = in_tail.fetchAdd(1, .acquire);
        const byte = in_buffer[tail % in_buffer.len];
        arch.serial.writer.print("\x1b[2K\r{d: >3}   0x{x:0>2}   '{c}'", .{ byte, byte, byte }) catch {};
    }
}

pub fn init() void {
    spawnKernelThread(&thread1, 0);
    spawnKernelThread(&thread2, 0);

    initialized = true;
}

var initialized: bool = false;
var current_tid: usize = 0;
pub fn saveThreadState(state: *align(1) const arch.arch.CPUState) void {
    if (!initialized) return;
    const thread = &threads.items[current_tid];
    thread.ext_cpu_state.save();
    thread.cpu_state = state.*;
}

pub fn schedule() noreturn {
    std.debug.assert(initialized);
    current_tid = (current_tid + 1) % threads.items.len;
    const thread = &threads.items[current_tid];

    thread.ext_cpu_state.load();
    thread.cpu_state.restore();
}
