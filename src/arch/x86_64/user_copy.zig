const std = @import("std");
const arch = @import("x86_64.zig");
const assert = std.debug.assert;

/// returns true if successful
pub noinline fn copyFromUser(noalias dst: []u8, noalias src: []allowzero const u8) bool {
    arch.interrupt.assertDisabled();
    assert(@intFromPtr(dst.ptr) >= arch.paging.min_kernel_addr);
    assert(dst.len == src.len);

    const src_end = std.math.add(usize, @intFromPtr(src.ptr), src.len) catch return false;
    if (src_end > arch.paging.max_user_addr) return false;

    const dst_ptr = dst.ptr;
    const src_ptr = src.ptr;
    const len = src.len;

    const out = asm volatile (
        \\ cld
        \\ copy_from_user_fault_ip:
        \\ rep movsb
        \\ movl $1, %eax
        \\ copy_from_user_done:
        : [out] "={rax}" (-> usize),
        : [dst] "{rdi}" (dst_ptr),
          [src] "{rsi}" (src_ptr),
          [len] "{rcx}" (len),
        : .{ .rcx = true, .rsi = true, .rdi = true, .cc = true, .memory = true });

    return out > 0;
}

pub extern const copy_from_user_fault_ip: anyopaque;
pub extern const copy_from_user_done: anyopaque;
