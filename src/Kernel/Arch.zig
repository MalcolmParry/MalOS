const builtin = @import("builtin");

const arch = switch (builtin.cpu.arch) {
    .x86_64 => @import("Arch/x86-64/Arch.zig"),
    else => @compileError("Unsupported architecture"),
};

pub usingnamespace arch;
