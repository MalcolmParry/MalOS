const std = @import("std");
const abi = @import("abi");
const lib = @import("lib.zig");
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

fn callMain(klog_h: usize, initrd_i: usize, vmar_h: usize) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    lib.klog = @enumFromInt(klog_h);
    lib.vmar = @enumFromInt(vmar_h);
    const initrd: abi.Handle = @enumFromInt(initrd_i);

    const Ret = @typeInfo(@TypeOf(root.main)).@"fn".return_type.?;
    switch (@typeInfo(Ret)) {
        .noreturn => {
            root.main(initrd);
        },
        .void => {
            root.main(initrd);
            lib.syscall.exit(0);
        },
        .error_union => |eu| {
            switch (eu.payload) {
                void, noreturn => {},
                else => @compileError("bad return type"),
            }

            root.main(initrd) catch |err| {
                std.log.err("main returned with {}", .{err});
                lib.syscall.exit(1);
            };

            lib.syscall.exit(0);
        },
        else => @compileError("bad return type"),
    }
}
