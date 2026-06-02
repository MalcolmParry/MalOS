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

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = std.testing.failing_allocator;
    };
};

fn kernelMain() noreturn {
    tty.clear();
    arch.interrupt.disable();
    arch.interrupt.init();

    arch.initBootInfo();

    for (pmm.available_ranges.items) |range| {
        std.log.info("Available: {f}\n", .{mem.fmtRange(range)});
    }

    std.log.info("Kernel {f}\n", .{mem.fmtRange(pmm.kernel_range)});
    std.log.info("KernelVirtBase: 0x{x}\n", .{mem.kernel_virt_base});

    pmm.tempInit();

    const page_table = arch.paging.init();
    var page_allocator_object: PageAllocator = .init(page_table, arch.paging.heap_range);
    const page_alloc = page_allocator_object.allocator();

    for (mem.modules.items) |*module| {
        module.data = @alignCast(page_allocator_object.mapRange(module.phys_range, .{
            .writable = true,
            .executable = false,
            .global = true,
            .kernel_only = true,
            .cache_mode = .full,
        }) catch @panic("can't map module"));
        std.log.info("Module '{s}' at {f} and mapped at 0x{x}\n", .{ module.name(), mem.fmtRange(module.phys_range), @intFromPtr(module.data.?.ptr) });
    }

    pmm.init(page_alloc);

    // var gpa_obj = std.heap.DebugAllocator(.{
    //     .thread_safe = false,
    // }){
    //     .backing_allocator = page_alloc,
    // };
    // defer _ = gpa_obj.deinit();
    // const gpa = gpa_obj.allocator();

    var page_count: usize = 0;
    while (page_count < 0x8_0000) {
        const result = page_alloc.alloc(u8, 1) catch break;
        _ = result;
        // page_alloc.free(result);
        page_count += 1;
    }

    std.log.info("Pages Allocated 0x{x}\nMemory Allocated {Bi}\n", .{ page_count, page_count * 4096 });

    // arch.interrupt.enable();
    arch.spinWait();
}

export fn kernelEntry() callconv(arch.boot_call_conv) noreturn {
    kernelMain();
}
