const std = @import("std");

fn main() callconv(.{ .x86_64_sysv = .{} }) noreturn {
    debugPrint("hello world\n") catch {};

    while (true) {
        std.atomic.spinLoopHint();
    }
}

fn debugPrint(msg: []const u8) !void {
    const result = syscall(.{ 0, @intFromPtr(msg.ptr), msg.len });
    if (result[0] != 0) return error.Failed;
}

fn syscall(args: [3]usize) [2]usize {
    var ret0: usize = undefined;
    var ret1: usize = undefined;

    asm volatile (
        \\ int $0x80
        : [ret0] "={rax}" (ret0),
          [ret1] "={rdi}" (ret1),
        : [arg0] "{rax}" (args[0]),
          [arg1] "{rdi}" (args[1]),
          [arg2] "{rsi}" (args[2]),
        : .{ .memory = true });

    return .{ ret0, ret1 };
}

var stack: [32 * 1024]u8 align(4096) = undefined;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ lea %[stack:P] + %[stack_len:c](%rip), %rsp
        \\ xor %ebp, %ebp
        \\ pushq $0
        \\ jmp %[main:P]
        :
        : [stack] "i" (&stack),
          [stack_len] "i" (stack.len),
          [main] "i" (&main),
    );
}
