const arch = @import("arch.zig");
const tty = @import("tty.zig");
const mem = @import("memory.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const PageAllocator = @import("PageAllocator.zig");
const std = @import("std");

pub const panic = @import("panic.zig").panic;
pub const std_options: std.Options = .{
    .logFn = tty.log,
    .page_size_min = mem.page_size,
    .page_size_max = mem.page_size,
};

var fixed_alloc_buffer: [512]u8 = undefined;
var fixed_alloc_struct = std.heap.FixedBufferAllocator.init(&fixed_alloc_buffer);
pub var fixed_alloc = fixed_alloc_struct.allocator();

extern fn functionInRodata() callconv(.{ .x86_64_sysv = .{} }) void;
const x: u32 = 5;

fn kernelMain() !void {
    tty.clear();
    arch.interrupt.disable();
    arch.interrupt.init();

    arch.initBootInfo(fixed_alloc);
    for (mem.phys_modules) |module| {
        std.log.info("Module '{s}' at {f}\n", .{ module.name, module.phys_range });
    }

    for (mem.available_ranges.items) |range| {
        std.log.info("Available: {f}\n", .{range});
    }

    std.log.info("Kernel {f}\n", .{mem.kernel_range});
    std.log.info("KernelVirtBase: {x}\n", .{mem.kernel_virt_base});

    pmm.tempInit();

    const page_table = arch.paging.init();
    var page_allocator_object: PageAllocator = .init(page_table, arch.paging.heap_range);
    const page_alloc = page_allocator_object.allocator();

    var page_count: usize = 0;
    while (page_count < 0x10_0000) {
        _ = page_alloc.alloc(u8, 1) catch break;
        page_count += 1;
    }

    std.log.info("Pages Allocated 0x{x}\nMemory Allocated {Bi}\n", .{ page_count, page_count * 4096 });

    const px: *volatile u32 = @constCast(&x);
    px.* = 2; // TODO: get this to cause an error

    // TODO: get this to cause error
    functionInRodata();

    // arch.Interrupt.Enable();
    arch.spinWait();
}

export fn KernelEntry() callconv(arch.boot_call_conv) noreturn {
    kernelMain() catch |err| {
        std.debug.panic("{}\n", .{err});
    };

    @panic("KernelMain returned\n");
}
