const builtin = @import("builtin");

pub const arch = switch (builtin.target.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    else => @compileError("unsupported arch"),
};

pub const ustar = @import("ustar.zig");
