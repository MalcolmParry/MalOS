const std = @import("std");
const arch = @import("../arch/arch.zig").current;
const Object = @import("../object/Object.zig");
const HandleTable = @import("HandleTable.zig");
const AddressSpace = @import("AddressSpace.zig");
const gpa = @import("../heap/gpa.zig").allocator;
const Process = @This();

obj: Object,
handle_table: HandleTable,
addr_space: AddressSpace,
arch_specific: arch.cpu.PerProcess,

pub fn create() !*Process {
    const proc = try gpa.create(Process);
    proc.* = .{
        .obj = .{
            .kind = .process,
            .ref_count = .init(1),
        },
        .handle_table = .init,
        .addr_space = undefined,
        .arch_specific = undefined,
    };

    proc.arch_specific.init();
    errdefer proc.arch_specific.deinit();
    try proc.addr_space.init();
    return proc;
}

pub fn destroy(proc: *Process) void {
    std.debug.assert(proc.obj.ref_count.load(.monotonic) == 0);
    proc.handle_table.deinit();
    proc.addr_space.deinit();
    proc.arch_specific.deinit();
    gpa.destroy(proc);
}
