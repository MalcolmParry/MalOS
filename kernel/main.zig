const arch = @import("arch/arch.zig").current;
const BootInfo = @import("BootInfo.zig");
const mem = @import("memory.zig");
const pmm = @import("pmm.zig");
const Vmm = @import("Vmm.zig");
const PageAllocator = @import("heap/PageAllocator.zig");
const std = @import("std");
const builtin = @import("builtin");
const scheduler = @import("task/scheduler.zig");
const Task = @import("task/Task.zig");
const AddressSpace = @import("task/AddressSpace.zig");
const log = @import("log.zig");
const gpa = @import("heap/gpa.zig");
const elf_loader = @import("elf_loader.zig");

const vfs = @import("fs/vfs/vfs.zig");
const Ramfs = @import("fs/Ramfs.zig");
const Ext2 = @import("fs/Ext2.zig");
const BlockDevice = @import("block/BlockDevice.zig");

const ata_pio = @import("drivers/x86/ata_pio.zig");
const pit = @import("drivers/x86/pit.zig");
const devfs = @import("fs/devfs.zig");
const pci = @import("drivers/pci.zig");

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
    log.writer.print("\x1b[H\x1b[2J\x1b[3J", .{}) catch {};

    var boot_info = arch.initBootInfo();
    try log.init(boot_info);

    for (boot_info.availablePhysRanges()) |range| {
        std.log.info("Available: {f}\x1b[48G{Bi}", .{ mem.fmtRange(range), range.len * mem.page_size });
    }

    std.log.info("Kernel {f}", .{mem.fmtRange(boot_info.kernel_phys_range)});
    std.log.info("KernelVirtBase: 0x{x}", .{mem.kernel_virt_base});
    std.log.info("Max Physical Address: 0x{x}", .{@intFromPtr(boot_info.max_phys_addr)});

    pmm.tempInit(&boot_info);

    const page_table = arch.paging.init(&boot_info);
    PageAllocator.global = .{
        .table = page_table,
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
    scheduler.init();
    pit.init();

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

    arch.interrupt.enable();
    try devfs.init();
    try log.registerConsoleFile();
    pci.check();

    try ata_pio.detectAndRegister();

    try ext2Test();

    // arch.spinWait();
    try scheduler.testing.run();
    scheduler.exitTask();
}

fn ext2Test() !void {
    const alloc = gpa.allocator;

    const devfs_mount = try devfs.mount();
    defer devfs_mount.unmount() catch |err| debug.dumpErrorAndPanic(err);

    const devfs_root = devfs_mount.acquireRootPath();
    defer devfs_root.release();

    try printFileTree(devfs_root, log.term, 0);

    const drive = try devfs_root.lookup("disk/ata0p0");
    defer drive.release();

    const root_mount = try Ext2.create(alloc, drive);
    defer root_mount.unmount() catch |err| debug.dumpErrorAndPanic(err);
    vfs.root = root_mount;
    defer vfs.root = null;

    const root = root_mount.acquireRootPath();
    defer root.release();

    const hello_txt = try root.lookup("hello.txt");
    defer hello_txt.release();

    const file = try hello_txt.open(.ro);
    defer file.release();

    var buffer: [1024]u8 = undefined;
    const read = try file.read(0, &buffer, .{});

    std.log.info("{} bytes read", .{read});
    std.log.info("{s}", .{buffer[0..read]});

    const dev_target = try root.lookup("dev");
    defer dev_target.release();
    try devfs_mount.mountOnto(dev_target);
    defer devfs_mount.makeOrphan();

    log.term.setColor(.blue) catch {};
    try log.term.writer.print("/", .{});
    log.term.setColor(.reset) catch {};
    try log.term.writer.print("\n", .{});
    try printFileTree(root, log.term, 1);
    log.writer.flush() catch {};

    _ = try Task.spawnKernelTask(init, .{});
    scheduler.sleepNs(std.time.ns_per_s * 2000000000);
}

fn init() !void {
    const task = Task.current_tid.get();
    task.handle_table = try .create();
    task.addr_space = try .create();
    const as = task.addr_space.?;
    as.table.use();

    const result = blk: {
        const root = vfs.root.?.acquireRootPath();
        defer root.release();

        const path = try root.lookup("/bin/init");
        defer path.release();

        const file = try path.open(.xo);
        defer file.release();

        break :blk try elf_loader.load(as, file);
    };

    var state = arch.cpu.getUserTaskFrame(.{
        .entry = result.entry,
        .phys_page_table = @intFromPtr(as.table.physPage()),
    });

    scheduler.preempt(&state);
}

fn printFileTree(parent: vfs.Path, term: std.Io.Terminal, indent: usize) !void {
    const file = try parent.open(.ro);
    defer file.release();

    var next_pos: u64 = 0;
    var record: vfs.DirRecord = undefined;
    while (true) {
        next_pos = (try file.readDir(next_pos, &record)) orelse break;

        for (0..indent) |_| try term.writer.print("    ", .{});

        term.setColor(switch (record.kind) {
            .file => .bright_white,
            .dir => .blue,
            .block_device => .bright_yellow,
            .char_device => .bright_magenta,
        }) catch {};

        try term.writer.print("{s}", .{record.getName()});
        term.setColor(.reset) catch {};
        try term.writer.print("\n", .{});

        if (record.kind == .dir) {
            const child = try parent.lookup(record.getName());
            defer child.release();

            try printFileTree(child, term, indent + 1);
        }
    }
}
