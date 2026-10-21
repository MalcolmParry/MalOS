const std = @import("std");
const lib = @import("lib");

pub fn main() noreturn {
    lib.syscall.debugPrint("hello world\n") catch {};

    while (true) {
        std.atomic.spinLoopHint();
    }
}

comptime {
    _ = lib;
}
