const arch = @import("arch/arch.zig").current;
const BootInfo = @import("BootInfo.zig");
const mem = @import("memory.zig");
const pmm = @import("pmm.zig");
const Vmm = @import("Vmm.zig");
const PageAllocator = @import("heap/PageAllocator.zig");
const std = @import("std");
const builtin = @import("builtin");
const scheduler = @import("proc/scheduler.zig");
const log = @import("log.zig");
const gpa = @import("heap/gpa.zig");
const elf_loader = @import("elf_loader.zig");
const ustar = @import("shared").ustar;
const Vmo = @import("object/Vmo.zig");
const Process = @import("proc/Process.zig");
const Thread = @import("proc/Thread.zig");

pub const debug = @import("debug.zig");
pub const panic = std.debug.FullPanic(debug.panic);
pub const std_options_debug_threaded_io = null;
pub const std_options_debug_io = std.Io.failing;
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

pub fn kernelMain() !noreturn {
    try log.preinit();
    arch.interrupt.init();

    var boot_info = arch.initBootInfo();
    try log.init(boot_info);

    for (boot_info.availablePhysRanges()) |range| {
        std.log.info("Available: {f}\x1b[48G{Bi}", .{ mem.fmtRange(range), range.len * mem.page_size });
    }

    std.log.info("Kernel {f}", .{mem.fmtRange(boot_info.kernel_phys_range)});
    std.log.info("KernelVirtBase: 0x{x}", .{mem.kernel_virt_base});
    std.log.info("Max Physical Address: 0x{x}", .{@intFromPtr(boot_info.max_phys_addr)});

    pmm.tempInit(&boot_info);

    arch.paging.init(&boot_info);
    PageAllocator.global = .{
        .table = arch.paging.getGlobalKernelTable(),
        .vmm = try Vmm.init(arch.paging.heap_range),
        .default_flags = .{
            .writable = true,
            .executable = false,
            .global = true,
            .user = false,
            .cache_mode = .full,
        },
        .lock = .init,
    };
    const page_alloc = PageAllocator.global.allocator();

    pmm.init(&boot_info, page_alloc);
    try arch.initTimer();
    try scheduler.init();
    try arch.initSmp();

    for (boot_info.module_buffer[0..boot_info.module_count]) |*module| {
        const phys_pages = mem.physPageAlignOutwards(module.phys_range);
        const pages = try PageAllocator.global.map(phys_pages, .{
            .writable = false,
            .executable = false,
            .global = true,
            .user = false,
            .cache_mode = .full,
        });
        const bytes = std.mem.sliceAsBytes(pages);
        module.data = bytes;

        std.log.info("Module '{s}' at {f} and mapped at 0x{x}", .{ module.name(), mem.fmtRange(module.phys_range), @intFromPtr(module.data.?.ptr) });
    }

    for (&boot_info.elf_sections.values, 0..) |*maybe_section, i| {
        const section = if (maybe_section.*) |*x| x else continue;
        const id: BootInfo.ElfSection.Id = @enumFromInt(i);

        const page_offset = @intFromPtr(section.phys_range.ptr) % mem.page_size;
        const phys_pages = mem.physPageAlignOutwards(section.phys_range);
        const pages = try PageAllocator.global.map(phys_pages, .{
            .writable = false,
            .executable = false,
            .global = true,
            .user = false,
            .cache_mode = .full,
        });

        const bytes = std.mem.sliceAsBytes(pages);
        section.data = (bytes.ptr + page_offset)[0..section.phys_range.len];

        std.log.info("Elf Section {} at {f} mapped at 0x{x}", .{ id, mem.fmtRange(section.phys_range), @intFromPtr(section.data.ptr) });
    }

    debug.init(&boot_info);
    std.log.info("{Bi:.2} used out of {Bi:.2}", .{ pmm.used_pages.load(.monotonic) * mem.page_size, pmm.total_pages * mem.page_size });

    const initrd = blk: for (boot_info.modules()) |*mod| {
        if (!std.mem.eql(u8, mod.name(), "initrd")) continue;
        break :blk mod;
    } else @panic("initrd not found");

    const vmo = try Vmo.fromOwnedSlice(initrd.phys_range);

    const stack_size = 1024 * 32;
    const stack = try PageAllocator.global.alloc(stack_size / mem.page_size, .{
        .global = true,
        .cache_mode = .full,
        .executable = false,
        .user = false,
        .writable = true,
    });

    const init_proc = try Process.create();
    init_proc.arch_specific.giveAllPermissions();
    const init_thread = try Thread.create(init_proc, stack);
    try init_thread.startWrapped(init, .{ initrd.data.?, vmo });

    init_thread.obj.release();
    init_proc.obj.release();
    Thread.exitCurrent();
}

fn init(initrd: []const u8, initrd_vmo: *Vmo) !noreturn {
    const thread = Thread.current;
    const proc = thread.proc.?;

    const klog_h = try proc.handle_table.putLocked(.{
        .obj = &log.log_obj,
        .rights = .{
            .duplicate = true,
            .transfer = true,
            .write = true,
        },
    });

    const initrd_h = try proc.handle_table.putLocked(.{
        .obj = &initrd_vmo.obj,
        .rights = .{
            .duplicate = true,
            .transfer = true,
            .read = true,
            .exec = true,
        },
    });

    proc.vmar.obj.acquire();
    const vmar_h = try proc.handle_table.putLocked(.{
        .obj = &proc.vmar.obj,
        .rights = .{
            .duplicate = true,
            .transfer = true,
            .read = true,
            .write = true,
            .exec = true,
        },
    });

    const init_elf = try ustar.lookup(initrd, "init") orelse return error.InitNotFound;
    const result = try elf_loader.load(proc.vmar, init_elf);

    const stack_size = 32 * 1024;
    const stack_vmo = try Vmo.create(stack_size);
    try stack_vmo.commitLocked(0, stack_size / mem.page_size);
    const stack_addr = proc.vmar.findGapLocked(stack_size / mem.page_size, null) orelse @panic("cant allocate init user stack");
    try proc.vmar.mapLocked(stack_vmo, 0, stack_addr, stack_size / mem.page_size, .{
        .w = true,
        .x = false,
    });

    var state = arch.cpu.getUserThreadFrame(.{
        .entry = result.entry,
        .args = .{ @intFromEnum(klog_h), @intFromEnum(initrd_h), @intFromEnum(vmar_h), 0, 0, 0 },
        .sp = stack_addr * mem.page_size + stack_size - 8,
    });

    scheduler.preempt(&state);
}
