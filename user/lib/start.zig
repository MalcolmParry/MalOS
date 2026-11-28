const std = @import("std");
const abi = @import("abi");
const lib = @import("lib.zig");
const root = @import("root");
const Handle = abi.syscall.Handle;

pub fn _start(args_vmo_i: usize) callconv(.{ .x86_64_sysv = .{} }) noreturn {
    const args_vmo: Handle = .fromUsizeUnsafe(args_vmo_i);
    const args_size = lib.syscall.vmoGetSize(args_vmo) catch @panic("");

    var header: abi.proc_args.Header = undefined;
    lib.syscall.vmoRead(args_vmo, 0, std.mem.asBytes(&header)) catch @panic("");
    lib.vmar = header.vmar;
    lib.klog = header.klog;

    const args = lib.syscall.vmarMap(lib.vmar, 0, args_vmo, 0, args_size, .{}) catch @panic("failed to map process args");
    lib.syscall.handleClose(args_vmo) catch unreachable;

    if (header.resource_count > 0) {
        lib.resources = @as([*]abi.proc_args.Resource, @ptrCast(@alignCast(args.ptr + header.resource_offset)))[0..header.resource_count];
    }

    const Ret = @typeInfo(@TypeOf(root.main)).@"fn".return_type.?;
    switch (@typeInfo(Ret)) {
        .noreturn => {
            root.main(header.initrd);
        },
        .void => {
            root.main(header.initrd);
            lib.syscall.threadExit();
        },
        .error_union => |eu| {
            switch (eu.payload) {
                void, noreturn => {},
                else => @compileError("bad return type"),
            }

            root.main(header.initrd) catch |err| {
                std.log.err("main returned with {}", .{err});
                lib.syscall.threadExit();
            };

            lib.syscall.threadExit();
        },
        else => @compileError("bad return type"),
    }
}
