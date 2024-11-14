pub fn hlt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn int(x: u8) void {
    asm volatile ("int %[x]"
        :
        : [x] "N" (x),
    );
}

pub fn sti() void {
    asm volatile ("sti");
}

pub fn cli() void {
    asm volatile ("cli");
}

pub fn out(port: u16, data: anytype) void {
    switch (@TypeOf(data)) {
        u8 => asm volatile ("outb %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{al}" (data),
        ),
        u16 => asm volatile ("outw %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{ax}" (data),
        ),
        u32 => asm volatile ("outl %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{eax}" (data),
        ),
        else => @compileError("Invalid data type. Expected u8, u16, or u32, found " ++ @typeName(@TypeOf(data))),
    }
}

pub fn in(comptime Type: type, port: u16) Type {
    return switch (Type) {
        u8 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        u16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        u32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        else => @compileError("Invalid data type. Expected u8, u16, ore u32, found " ++ @typeName(Type)),
    };
}

export fn memcpy(dest: [*]u8, src: [*]u8, size: usize) callconv(.C) void {
    for (0..size) |i| {
        dest[i] = src[i];
    }
}

export fn memset(dest: [*]u8, value: u32, size: usize) callconv(.C) [*]u8 {
    for (0..size) |i| {
        dest[i] = @intCast(value);
    }

    return dest;
}
