const std = @import("std");
const arch = @import("x86_64.zig");
const assert = std.debug.assert;

/// returns true if successful
pub fn copyFromUser(noalias dst: []u8, noalias src: []allowzero const u8) bool {
    arch.interrupt.assertDisabled();
    assert(@intFromPtr(dst.ptr) >= arch.paging.min_kernel_addr);
    assert(dst.len == src.len);

    const src_end = std.math.add(usize, @intFromPtr(src.ptr), src.len) catch return false;
    if (src_end > arch.paging.max_user_addr) return false;

    const dst_ptr = dst.ptr;
    const src_ptr = src.ptr;
    const len = src.len;

    const out = asm volatile (
        \\ lea 1f(%rip), %rdx
        \\ jmp %[memcpy_no_fault:P]
        \\ 1:
        : [out] "={rax}" (-> usize),
        : [dst] "{rdi}" (dst_ptr),
          [src] "{rsi}" (src_ptr),
          [len] "{rcx}" (len),
          [memcpy_no_fault] "i" (&memcpyNoFault),
        : .{ .rdi = true, .rsi = true, .rcx = true, .rdx = true, .cc = true, .memory = true });

    return out > 0;
}

/// returns true if successful
pub fn copyToUser(noalias dst: []allowzero u8, noalias src: []const u8) bool {
    arch.interrupt.assertDisabled();
    assert(@intFromPtr(src.ptr) >= arch.paging.min_kernel_addr);
    assert(dst.len == src.len);

    const dst_end = std.math.add(usize, @intFromPtr(dst.ptr), dst.len) catch return false;
    if (dst_end > arch.paging.max_user_addr) return false;

    const dst_ptr = dst.ptr;
    const src_ptr = src.ptr;
    const len = src.len;

    const out = asm volatile (
        \\ lea 1f(%rip), %rdx
        \\ jmp %[memcpy_no_fault:P]
        \\ 1:
        : [out] "={rax}" (-> usize),
        : [dst] "{rdi}" (dst_ptr),
          [src] "{rsi}" (src_ptr),
          [len] "{rcx}" (len),
          [memcpy_no_fault] "i" (&memcpyNoFault),
        : .{ .rdi = true, .rsi = true, .rcx = true, .rdx = true, .cc = true, .memory = true });

    return out > 0;
}

fn memcpyNoFault() callconv(.naked) void {
    asm volatile (
        \\ cld
        \\ memcpy_fault_ip:
        \\ rep movsb
        \\ movl $1, %eax
        \\ jmp *%rdx
    );
}

pub fn maybeHandleFault(state: *align(1) arch.cpu.State) bool {
    if (state.rip != @intFromPtr(&memcpy_fault_ip)) return false;

    const cr2: usize = asm volatile (
        \\mov %%cr2, %[out]
        : [out] "=r" (-> usize),
    );
    if (cr2 >= arch.paging.min_kernel_addr) return false;

    state.rax = 0;
    state.rip = state.rdx;
    return true;
}

extern const memcpy_fault_ip: anyopaque;
