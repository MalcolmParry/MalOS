const std = @import("std");
const abi = @import("abi");
const lib = @import("lib.zig");
const root = @import("root");

pub fn _start(klog_h: usize, initrd_i: usize, vmar_h: usize) callconv(.{ .x86_64_sysv = .{} }) noreturn {
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
            lib.syscall.threadExit();
        },
        .error_union => |eu| {
            switch (eu.payload) {
                void, noreturn => {},
                else => @compileError("bad return type"),
            }

            root.main(initrd) catch |err| {
                std.log.err("main returned with {}", .{err});
                lib.syscall.threadExit();
            };

            lib.syscall.threadExit();
        },
        else => @compileError("bad return type"),
    }
}
