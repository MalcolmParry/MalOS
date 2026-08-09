const arch = @import("arch.zig");
const tty = @import("tty.zig");
const mem = @import("memory.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const PageAllocator = @import("PageAllocator.zig");
const std = @import("std");
const builtin = @import("builtin");
const scheduler = @import("scheduler.zig");
const vfs = @import("fs/vfs.zig");
const Ramfs = @import("fs/Ramfs.zig");
const log = @import("log.zig");

pub const panic = @import("panic.zig").panic;
pub const std_options: std.Options = .{
    .logFn = log.log,
    .page_size_min = mem.page_size,
    .page_size_max = mem.page_size,
};

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = std.testing.failing_allocator;
    };
};

pub fn kernelMain() noreturn {
    arch.serial.init();
    arch.interrupt.init();

    var boot_info = arch.initBootInfo();

    for (boot_info.availablePhysRanges()) |range| {
        std.log.info("Available: {f}\x1b[48G{Bi}", .{ mem.fmtRange(range), range.len * mem.page_size });
    }

    std.log.info("Kernel {f}", .{mem.fmtRange(boot_info.kernel_phys_range)});
    std.log.info("KernelVirtBase: 0x{x}", .{mem.kernel_virt_base});

    pmm.tempInit(&boot_info);

    const page_table = arch.paging.init(&boot_info);
    var page_allocator_object: PageAllocator = .init(page_table, arch.paging.heap_range);
    const page_alloc = page_allocator_object.allocator();
    pmm.init(&boot_info, page_alloc);

    for (boot_info.module_buffer[0..boot_info.module_count]) |*module| {
        module.data = @alignCast(page_allocator_object.mapRange(module.phys_range, .{
            .writable = false,
            .executable = false,
            .global = true,
            .user = false,
            .cache_mode = .full,
        }) catch @panic("can't map module"));
        std.log.info("Module '{s}' at {f} and mapped at 0x{x}", .{ module.name(), mem.fmtRange(module.phys_range), @intFromPtr(module.data.?.ptr) });
    }

    @import("panic.zig").loadSymbolTable(boot_info.modules());

    // var gpa_obj = std.heap.DebugAllocator(.{
    //     .thread_safe = false,
    // }){
    //     .backing_allocator = page_alloc,
    // };
    // defer _ = gpa_obj.deinit();
    // const gpa = gpa_obj.allocator();

    var page_count: usize = 0;
    while (page_count < 0x4000) {
        const result = page_alloc.alloc(u8, 1) catch break;
        // _ = result;
        page_alloc.free(result);
        page_count += 1;
    }

    std.log.info("Pages Allocated 0x{x}", .{page_count});
    std.log.info("Memory Allocated {Bi}", .{page_count * mem.page_size});
    std.log.info("{Bi} used out of {Bi}", .{ pmm.used_pages.load(.monotonic) * mem.page_size, pmm.total_pages * mem.page_size });

    scheduler.init();
    arch.pit.init();
    scheduler.schedule();
}

comptime {
    if (!builtin.is_test) {
        @export(&arch.kernelEntry, .{ .name = "kernelEntry" });
    }
}

test {
    _ = @import("fs/Ramfs.zig");
}
