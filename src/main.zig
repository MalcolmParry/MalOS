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

extern fn functionInRodata() callconv(.{ .x86_64_sysv = .{} }) void;
const x: u32 = 5;

fn kernelMain() noreturn {
    arch.vga.init();
    tty.clear();
    arch.interrupt.disable();
    arch.interrupt.init();

    arch.initBootInfo();
    for (pmm.modules.items) |module| {
        std.log.info("Module '{s}' at {f}\n", .{ module.name(), module.range });
    }

    for (pmm.available_ranges.items) |range| {
        std.log.info("Available: {f}\n", .{range});
    }

    std.log.info("Kernel {f}\n", .{pmm.kernel_range});
    std.log.info("KernelVirtBase: {x}\n", .{mem.kernel_virt_base});

    pmm.tempInit();

    const page_table = arch.paging.init();
    var page_allocator_object: PageAllocator = .init(page_table, arch.paging.heap_range);
    const page_alloc = page_allocator_object.allocator();

    pmm.init(page_alloc);

    var page_count: usize = 0;
    while (page_count < 0x10_0000) {
        const result = page_alloc.alloc(u8, 1) catch break;
        page_alloc.free(result);
        page_count += 1;
    }

    std.log.info("Pages Allocated 0x{x}\nMemory Allocated {Bi}\n", .{ page_count, page_count * 4096 });

    const px: *volatile u32 = @constCast(&x);
    px.* = 2; // TODO: get this to cause an error

    // TODO: get this to cause error
    functionInRodata();

    // arch.interrupt.enable();
    arch.spinWait();
}

export fn KernelEntry() callconv(arch.boot_call_conv) noreturn {
    kernelMain();
}
