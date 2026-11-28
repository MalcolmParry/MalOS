pub fn out(port: u16, data: anytype) void {
    switch (@bitSizeOf(@TypeOf(data))) {
        8 => asm volatile ("outb %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{al}" (data),
        ),
        16 => asm volatile ("outw %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{ax}" (data),
        ),
        32 => asm volatile ("outl %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{eax}" (data),
        ),
        else => @compileError("bit size of type must be 8, 16, or 32. found " ++ @typeName(@TypeOf(data))),
    }
}

pub fn outb(port: u16, data: u8) void {
    out(port, data);
}

pub fn outw(port: u16, data: u16) void {
    out(port, data);
}

pub fn outl(port: u16, data: u32) void {
    out(port, data);
}

pub fn in(comptime T: type, port: u16) T {
    return switch (@bitSizeOf(T)) {
        8 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> T),
            : [port] "N{dx}" (port),
        ),
        16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> T),
            : [port] "N{dx}" (port),
        ),
        32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> T),
            : [port] "N{dx}" (port),
        ),
        else => @compileError("bit size of type must be 8, 16, or 32. found " ++ @typeName(T)),
    };
}

pub fn repInsw(port: u16, buffer: []align(1) u16) void {
    asm volatile (
        \\ cld
        \\ rep insw
        :
        : [port] "{dx}" (port),
          [buffer] "{rdi}" (buffer.ptr),
          [count] "{rcx}" (buffer.len),
        : .{ .rdi = true, .rcx = true, .memory = true, .dirflag = true });
}

pub fn ioWait() void {
    out(0x80, @as(u8, 0));
}
