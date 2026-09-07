const arch = @import("arch/arch.zig").current;
const mem = @import("memory.zig");
const pmm = @import("pmm.zig");
const Vmm = @import("Vmm.zig");
const PageAllocator = @import("heap/PageAllocator.zig");
const std = @import("std");
const builtin = @import("builtin");
const scheduler = @import("scheduler.zig");
const log = @import("log.zig");

const vfs = @import("fs/vfs.zig");
const Ramfs = @import("fs/Ramfs.zig");
const Ext2 = @import("fs/Ext2.zig");
const BlockDevice = @import("BlockDevice.zig");

const ata_pio = @import("drivers/x86/ata_pio.zig");
const pit = @import("drivers/x86/pit.zig");
const devfs = @import("fs/devfs.zig");

pub const panic = @import("panic.zig").panic;
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

pub fn kernelMain() noreturn {
    log.init();
    arch.interrupt.init();

    var boot_info = arch.initBootInfo();

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
        .vmm = Vmm.init(arch.paging.heap_range) catch @panic("failed to init vmm"),
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

    for (boot_info.module_buffer[0..boot_info.module_count]) |*module| {
        const phys_pages = mem.physPageAlignOutwards(module.phys_range);
        const pages = PageAllocator.global.map(phys_pages, .{
            .writable = false,
            .executable = false,
            .global = true,
            .user = false,
            .cache_mode = .full,
        }) catch @panic("can't map module");
        const bytes = std.mem.sliceAsBytes(pages);
        module.data = bytes;

        std.log.info("Module '{s}' at {f} and mapped at 0x{x}", .{ module.name(), mem.fmtRange(module.phys_range), @intFromPtr(module.data.?.ptr) });
    }

    @import("panic.zig").loadSymbolTable(boot_info.modules());

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

    // fsTest() catch |err| {
    //     std.debug.panic("fs test failed: {}", .{err});
    // };

    ata_pio.detectAndRegister() catch @panic("failed to detect and register ata devices");

    ext2Test() catch |err| {
        if (@errorReturnTrace()) |trace| {
            const len = @min(trace.instruction_addresses.len, trace.index);

            for (trace.instruction_addresses[0..len]) |addr| {
                @import("panic.zig").writeTraceAddr(addr);
            }
        }

        std.log.err("ext2 test failed: {}", .{err});
        arch.interrupt.disable();
        arch.spinWait();
    };

    arch.spinWait();
    // scheduler.init();
    // pit.init();
    // scheduler.schedule();
}

fn fsTest() !void {
    const alloc = PageAllocator.global.allocator();

    var ramfs: Ramfs = undefined;
    const root = try ramfs.init(alloc);
    defer {
        root.decRef();
        ramfs.deinit();
    }

    const dentry = try root.node.vtable.node_create(root, "thing.txt", .{ .kind = .file });
    defer dentry.decRef();
    defer root.node.vtable.node_unlink(root, dentry) catch @panic("");

    const open = try dentry.node.vtable.file_open(dentry.node);
    defer open.node.vtable.file_close(open);

    const test_str = "hello world";
    std.debug.assert(try open.write(test_str) == test_str.len);

    open.head = 0;
    var buffer: [test_str.len]u8 = undefined;
    std.debug.assert(try open.read(&buffer) == test_str.len);
    std.debug.assert(std.mem.eql(u8, buffer[0..], test_str));
}

fn ext2Test() !void {
    const alloc = PageAllocator.global.allocator();

    const drive_dentry = try devfs.root.lookupLocal("disk/ata0");
    defer drive_dentry.release();
    const bd = drive_dentry.node.data.block_device;

    var fs: Ext2 = undefined;
    const root = try fs.init(alloc, bd);
    defer {
        root.release();
        fs.deinit();
    }

    const hello_txt = try root.lookupLocal("hello.txt");
    defer hello_txt.release();

    const file = try hello_txt.node.open();
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const read = try file.read(&buffer);

    std.log.info("{} bytes read", .{read});
    std.log.info("{s}", .{buffer[0..read]});

    var devfs_mount: vfs.Mount = undefined;

    vfs.root = .{
        .target = null,
        .src = root,

        .parent = null,
        .first_child = &devfs_mount,
        .next_sibling = null,
    };

    const dev_target = try root.lookupNameLocal("dev");
    defer dev_target.release();

    devfs_mount = .{
        .target = dev_target,
        .src = &devfs.root,

        .parent = &vfs.root,
        .first_child = null,
        .next_sibling = null,
    };

    const root_path = vfs.root.acquireRootPath();
    defer root_path.release();

    log.term.setColor(.blue) catch {};
    try log.term.writer.print("/", .{});
    log.term.setColor(.reset) catch {};
    try log.term.writer.print("\n", .{});
    try printFileTree(root_path, log.term, 1);
}

fn printFileTree(parent: vfs.Path, term: std.Io.Terminal, indent: usize) !void {
    const file = try parent.dentry.node.open();
    defer file.close();

    var record: vfs.DirRecord = undefined;
    while (try file.readDir(&record)) {
        for (0..indent) |_| try term.writer.print("    ", .{});

        term.setColor(switch (record.kind) {
            .file => .white,
            .dir => .blue,
            .block_device => .yellow,
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
