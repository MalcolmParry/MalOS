const arch = @import("arch/arch.zig").current;
const boot_info = @import("boot_info.zig");
const mem = @import("mem/memory.zig");
const pmm = @import("mem/pmm.zig");
const std = @import("std");
const builtin = @import("builtin");
const scheduler = @import("proc/scheduler.zig");
const elf_loader = @import("elf_loader.zig");
const ustar = @import("shared").ustar;
const Vmo = @import("object/Vmo.zig");
const KLog = @import("object/KLog.zig");
const Process = @import("proc/Process.zig");
const Thread = @import("proc/Thread.zig");
const Resource = @import("object/Resource.zig");
const virt_layout = @import("mem/virt_layout.zig");

pub const debug = @import("debug.zig");
pub const panic = std.debug.FullPanic(debug.panic);
pub const std_options_debug_threaded_io = null;
pub const std_options_debug_io = std.Io.failing;
pub const std_options: std.Options = .{
    .logFn = KLog.log,
    .page_size_min = mem.page_size,
    .page_size_max = mem.page_size,
    .log_level = .debug,
};

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = std.testing.failing_allocator;
    };
};

pub fn kernelMain() !noreturn {
    try KLog.preinit();
    arch.interrupt.init();

    arch.initBootInfo();
    try KLog.init();

    inline for (virt_layout.regions) |region| {
        std.log.info("region {s: <16} at {f} {Bi}", .{ @tagName(region.name), mem.fmtRange(region.slice), region.size });
    }

    for (boot_info.available_phys_ranges.items) |range| {
        std.log.info("Available: {f}\x1b[48G{Bi}", .{ mem.fmtRange(range), range.len * mem.page_size });
    }

    std.log.info("Kernel {f}", .{mem.fmtRange(boot_info.kernel_phys_range)});
    std.log.info("KernelVirtBase: 0x{x}", .{mem.kernel_virt_base});
    std.log.info("Max Physical Address: 0x{x}", .{@intFromPtr(boot_info.max_phys_addr)});

    pmm.init();

    arch.paging.init();
    debug.init();
    try arch.time.init();
    try scheduler.init();
    try arch.initSmp();

    std.log.info("{Bi:.2} used out of {Bi:.2}", .{ pmm.used_pages.load(.monotonic) * mem.page_size, pmm.total_pages * mem.page_size });

    const initrd = blk: for (boot_info.modules.items) |*mod| {
        if (!std.mem.eql(u8, mod.name(), "initrd")) continue;
        break :blk mod;
    } else @panic("initrd not found");

    const vmo = try Vmo.fromOwnedSlice(initrd.data);
    const init_proc = try Process.create();
    const init_thread = try Thread.create(init_proc);
    try init_thread.startWrapped(init, .{ mem.physToDirect(initrd.data), vmo });

    init_thread.obj.release();
    init_proc.obj.release();
    Thread.exitCurrent();
}

fn init(initrd: []const u8, initrd_vmo: *Vmo) !noreturn {
    const thread = Thread.current();
    const proc = thread.proc.?;

    const klog = try KLog.create();
    const klog_h = try proc.handle_table.putLocked(.{
        .obj = &klog.obj,
        .rights = .{
            .duplicate = true,
            .transfer = true,
            .write = true,
            .read = true,
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

    const serial_backend = try Resource.create(.klog_backend_serial);
    const serial_backend_h = try proc.handle_table.putLocked(.{
        .obj = &serial_backend.obj,
        .rights = .{ .duplicate = true, .transfer = true },
    });

    const ioports = try Resource.create(.x86_ioports);
    ioports.len = 65536;
    const ioports_h = try proc.handle_table.putLocked(.{
        .obj = &ioports.obj,
        .rights = .{ .duplicate = true, .transfer = true },
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
        .args = .{ @backingInt(klog_h), @backingInt(initrd_h), @backingInt(vmar_h), @backingInt(serial_backend_h), @backingInt(ioports_h), 0 },
        .sp = stack_addr * mem.page_size + stack_size - 8,
    });

    scheduler.preempt(&state);
}
