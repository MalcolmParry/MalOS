const std = @import("std");
const arch = @import("../arch/arch.zig").current;
const pmm = @import("../pmm.zig");
const mem = @import("../memory.zig");
const Spinlock = @import("../sync/Spinlock.zig");

const stack_count = mem.getRegion(.kernel_stacks).size / stack_and_guard_size;
const stack_size = mem.page_align.forward(32 * 1024);
const stack_page_count = stack_size / mem.page_size;
const stack_and_guard_size = stack_size + mem.page_size;

var lock: Spinlock = .init;
var bump: usize = 0;
var first_stack: ?*usize = null;

pub fn alloc() ![]mem.Page {
    const l = lock.lock();
    defer l.unlock();

    if (first_stack) |link| {
        first_stack = @ptrFromInt(link.*);
        return @as([*]mem.Page, @ptrCast(@alignCast(link)))[0..stack_page_count];
    }

    const i = bump;
    if (i >= stack_count) return error.OutOfMemory;
    const addr = mem.getRegion(.kernel_stacks).base + (i * stack_and_guard_size) + mem.page_size;
    const stack = @as([*]mem.Page, @ptrFromInt(addr))[0..stack_page_count];
    try arch.paging.allocAndMap(stack, .kernel_rw);

    bump += 1;
    return stack;
}

// TODO: add unmapping
pub fn free(stack: []mem.Page) void {
    const l = lock.lock();
    defer l.unlock();

    const link: *usize = @ptrCast(stack.ptr);
    link.* = @intFromPtr(first_stack);
    first_stack = link;
}
