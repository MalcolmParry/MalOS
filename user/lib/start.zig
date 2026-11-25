const std = @import("std");
const abi = @import("abi");
const lib = @import("lib.zig");
const root = @import("root");

pub fn _start(klog_h: usize, initrd_i: usize, vmar_h: usize, serial_backend_i: usize) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    lib.klog = .fromUsizeUnsafe(klog_h);
    lib.vmar = .fromUsizeUnsafe(vmar_h);
    const initrd: abi.Handle = .fromUsizeUnsafe(initrd_i);
    const serial_backend: abi.Handle = .fromUsizeUnsafe(serial_backend_i);

    const Ret = @typeInfo(@TypeOf(root.main)).@"fn".return_type.?;
    switch (@typeInfo(Ret)) {
        .noreturn => {
            root.main(initrd, serial_backend);
        },
        .void => {
            root.main(initrd, serial_backend);
            lib.syscall.threadExit();
        },
        .error_union => |eu| {
            switch (eu.payload) {
                void, noreturn => {},
                else => @compileError("bad return type"),
            }

            root.main(initrd, serial_backend) catch |err| {
                std.log.err("main returned with {}", .{err});
                lib.syscall.threadExit();
            };

            lib.syscall.threadExit();
        },
        else => @compileError("bad return type"),
    }
}
