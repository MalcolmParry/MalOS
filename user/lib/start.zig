const root = @import("root");

var stack: [32 * 1024]u8 align(4096) = undefined;

pub fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ lea %[stack:P] + %[stack_len:c](%rip), %rsp
        \\ xor %ebp, %ebp
        \\ pushq $0
        \\ jmp %[call_main:P]
        :
        : [stack] "i" (&stack),
          [stack_len] "i" (stack.len),
          [call_main] "i" (&callMain),
    );
}

fn callMain(klog_h: usize) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    root.main(@enumFromInt(klog_h));
}
