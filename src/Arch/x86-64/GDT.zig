const GDT = struct {
    const Entry = u64;

    const Ptr = packed struct {
        sizeBytes: u16,
        ptr: u64,
    };

    const nullDescriptor: Entry = 0;
    const codeDescriptor: Entry = (1 << 43) | (1 << 44) | (1 << 47) | (1 << 53);
    const descriptors: [2]Entry = .{ nullDescriptor, codeDescriptor };
};

pub fn InitGDT() void {
    const gdtr: GDT.Ptr = .{
        .ptr = @intFromPtr(&GDT.descriptors),
        .sizeBytes = @sizeOf(GDT.Entry) * GDT.descriptors.len - 1,
    };

    asm volatile (
        \\lgdt (%[addr])
        :
        : [addr] "rax" (&gdtr),
    );
}
