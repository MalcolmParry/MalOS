const builtin = @import("builtin");

pub const current = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64/x86_64.zig"),
    else => @compileError("Unknown architecture."),
};
