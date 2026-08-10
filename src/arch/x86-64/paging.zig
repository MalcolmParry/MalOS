const std = @import("std");
const gdt = @import("gdt.zig");
const mem = @import("../../memory.zig");
const vmm = @import("../../vmm.zig");
const pmm = @import("../../pmm.zig");
const arch = @import("arch.zig");
const BootInfo = @import("../../BootInfo.zig");

pub const Entry = packed struct(u64) {
    present: bool,
    writable: bool,
    user: bool,
    write_through: bool,
    disable_cache: bool,
    /// cpu sets this, should be set to false by default
    accessed: bool = false,
    /// cpu sets this, should be set to false by default
    dirty: bool = false,
    huge: bool,
    global: bool,
    available: u3 = 0,
    address: u40, // address divided by 4096
    available2: u7 = 0,
    prot_key: u4 = 0,
    disable_execute: bool,

    const blank: Entry = .{
        .present = false,
        .writable = false,
        .user = false,
        .write_through = false,
        .disable_cache = false,
        .huge = false,
        .global = false,
        .address = 0,
        .disable_execute = false,
    };

    pub fn getPhysAddr(entry: Entry) *mem.PhysPage {
        return @ptrFromInt(entry.address * 4096);
    }

    /// only use if this entry isn't a leaf
    pub fn getLower(entry: Entry) *Table {
        std.debug.assert(!entry.huge);
        return @ptrFromInt(entry.address * 4096 + @intFromPtr(direct_map.ptr));
    }

    /// dont use on a leaf
    pub fn getLowerSafe(entry: Entry) ?*Table {
        if (!entry.present) return null;
        return entry.getLower();
    }
};

/// table | table maps | entry maps
/// l1    | 2   mb     | 4   kb
/// l2    | 1   gb     | 2   mb
/// l3    | 512 gb     | 1   gb
/// l4    | 256 tb     | 512 gb
pub const Table = extern struct {
    pub const Index = u9;

    entries: [512]Entry align(4096),

    comptime {
        std.debug.assert(@sizeOf(Table) == 4096);
        std.debug.assert(@alignOf(Table) == 4096);
    }

    fn clear(table: *Table) void {
        @memset(&table.entries, .blank);
    }

    const Level = enum(u2) {
        l1,
        l2,
        l3,
        l4,
    };
};

fn getOrCreateTable(entry: *Entry) !*Table {
    if (entry.present) return entry.getLower();

    const phys = try pmm.allocatePage();
    errdefer pmm.freePage(phys);

    const phys_index = @intFromPtr(phys) / mem.page_size;
    const direct = &direct_map[phys_index];
    const table: *Table = @ptrCast(direct);
    table.clear();

    entry.* = .{
        .present = true,
        .writable = true,
        .user = false,
        .write_through = false,
        .disable_cache = false,
        .huge = false,
        .global = false,
        .address = @intCast(phys_index),
        .disable_execute = false,
    };

    return table;
}

pub fn mapPage(table: *Table, level: Table.Level, virt: *mem.Page, phys: *mem.PhysPage, page_flags: vmm.PageFlags) !void {
    const indices = getIndicesFromVirtAddr(@intFromPtr(virt));

    var cur = table;
    var cur_level: u8 = @intFromEnum(level);
    while (cur_level > 0) : (cur_level -= 1) {
        cur = try getOrCreateTable(&cur.entries[indices[cur_level]]);
    }

    const entry = &cur.entries[indices[0]];
    std.debug.assert(!entry.present);

    entry.* = .{
        .present = true,
        .writable = page_flags.writable,
        .user = page_flags.user,
        .write_through = page_flags.cache_mode == .write_through,
        .disable_cache = page_flags.cache_mode == .disabled,
        .huge = false,
        .global = page_flags.global,
        .address = @intCast(@intFromPtr(phys) / mem.page_size),
        .disable_execute = !page_flags.executable,
    };
}

pub fn getPhysFromVirt(l4: *Table, virt: *mem.Page) *mem.PhysPage {
    const indices = getIndicesFromVirtAddr(@intFromPtr(virt));

    const l3 = l4.entries[indices[3]].getLowerSafe() orelse @panic("not mapped");
    const l2 = l3.entries[indices[2]].getLowerSafe() orelse @panic("not mapped");
    const l1 = l2.entries[indices[1]].getLowerSafe() orelse @panic("not mapped");
    const l1_ent = l1.entries[indices[0]];
    if (!l1_ent.present) @panic("not mapped");
    return l1_ent.getPhysAddr();
}

pub fn isAvailable(l4: *Table, virt: *mem.Page) bool {
    const indices = getIndicesFromVirtAddr(@intFromPtr(virt));

    const l3 = l4.entries[indices[3]].getLowerSafe() orelse return true;
    const l2 = l3.entries[indices[2]].getLowerSafe() orelse return true;
    const l2_ent = &l2.entries[indices[1]];
    if (!l2_ent.present) return true;
    if (l2_ent.huge) return false;

    const l1 = l2_ent.getLower();
    return !l1.entries[indices[0]].present;
}

pub fn isRegionAvailable(l4: *Table, region: []mem.Page) bool {
    for (region) |*page| {
        if (!isAvailable(l4, page)) return false;
    }

    return true;
}

pub fn clearEntry(l4: *Table, virt: *mem.Page) void {
    const indices = getIndicesFromVirtAddr(@intFromPtr(virt));

    const l3 = l4.entries[indices[3]].getLowerSafe() orelse @panic("not mapped");
    const l2 = l3.entries[indices[2]].getLowerSafe() orelse @panic("not mapped");
    const l2_ent = &l2.entries[indices[1]];
    if (!l2_ent.present) @panic("not mapped");
    if (l2_ent.huge) @panic("cant clear huge page entry");

    const l1 = l2_ent.getLower();
    l1.entries[indices[0]] = .blank;
    invalidatePage(virt);
}

pub fn getIndicesFromVirtAddr(addr: usize) [4]Table.Index {
    const l4 = (addr >> 39) & 0x1ff;
    const l3 = (addr >> 30) & 0x1ff;
    const l2 = (addr >> 21) & 0x1ff;
    const l1 = (addr >> 12) & 0x1ff;
    return .{
        @intCast(l1),
        @intCast(l2),
        @intCast(l3),
        @intCast(l4),
    };
}
fn getVirtAddrFromIndices(l4: Table.Index, l3: Table.Index, l2: Table.Index, l1: Table.Index) *mem.Page {
    const ul4: usize = l4;
    const ul3: usize = l3;
    const ul2: usize = l2;
    const ul1: usize = l1;

    const addr: usize = (ul1 << 12) | (ul2 << 21) | (ul3 << 30) | (ul4 << 39);
    const mask: usize = @truncate(std.math.boolMask(usize, true) << 48);
    const full: usize = addr | if (l4 & (1 << 8) != 0) mask else 0;
    return @ptrFromInt(full);
}

pub const heap_range = @as([*]mem.Page, @ptrCast(getVirtAddrFromIndices(511, 0, 0, 0)))[0 .. 512 * 512 * 511];
const direct_map = @as([*]mem.Page, @ptrCast(getVirtAddrFromIndices(256, 0, 0, 0)))[0 .. 512 * 512 * 512];

pub var l4_table: Table = undefined;
var l3_kernel_table: Table = undefined;
var l2_init_kernel_table: Table = undefined;
var l2_kernel_table: Table = undefined;

var direct_map_l3: Table = undefined;
var first_direct_map_l2: Table = undefined;

comptime {
    @export(&l4_table.entries, .{ .name = "page_table_l4_virt" });
    @export(&l3_kernel_table.entries, .{ .name = "page_table_l3_virt" });
    @export(&l2_init_kernel_table.entries, .{ .name = "page_table_l2_virt" });
}

fn enableExecuteDisable() void {
    const msr = 0xc000_0080;
    const old = arch.readMSR(msr);
    arch.writeMSR(msr, old | (1 << 11));
}

pub fn init(boot_info: *const BootInfo) *Table {
    enableExecuteDisable();
    gdt.init();

    @memset(l4_table.entries[0..511], .blank);
    @memset(l3_kernel_table.entries[0..511], .blank);

    if (@intFromPtr(boot_info.max_phys_addr) > 1024 * 1024 * 1024)
        @panic("too much virtual memory to direct map with 1 l2 table");

    for (&first_direct_map_l2.entries, 0..) |*entry, i| {
        entry.* = .{
            .present = true,
            .writable = true,
            .user = false,
            .write_through = false,
            .disable_cache = false,
            .huge = true,
            .global = true,
            .address = @intCast(i * 512),
            .disable_execute = true,
        };
    }

    @memset(direct_map_l3.entries[1..], .blank);
    direct_map_l3.entries[0] = .{
        .present = true,
        .writable = true,
        .user = false,
        .write_through = false,
        .disable_cache = false,
        .huge = false,
        .global = false,
        .address = @intCast((@intFromPtr(&first_direct_map_l2) - mem.kernel_virt_base) / mem.page_size),
        .disable_execute = false,
    };

    l4_table.entries[256] = .{
        .present = true,
        .writable = true,
        .user = false,
        .write_through = false,
        .disable_cache = false,
        .huge = false,
        .global = false,
        .address = @intCast((@intFromPtr(&direct_map_l3) - mem.kernel_virt_base) / mem.page_size),
        .disable_execute = false,
    };

    invalidatePages();

    l2_kernel_table.clear();
    for (boot_info.kernelRegions()) |region| {
        for (region.pages) |*page| {
            if (@intFromPtr(page) < mem.kernel_virt_base) continue;
            const phys: *mem.PhysPage = @ptrFromInt(@intFromPtr(page) - mem.kernel_virt_base);
            std.debug.assert(@intFromPtr(phys) < 4096 * 512 * 512);

            mapPage(&l2_kernel_table, .l2, page, phys, region.flags) catch @panic("failed to map kernel");
        }
    }

    l3_kernel_table.entries[511] = .{
        .present = true,
        .writable = true,
        .user = false,
        .write_through = false,
        .disable_cache = false,
        .huge = false,
        .global = false,
        .address = @intCast((@intFromPtr(&l2_kernel_table.entries) - mem.kernel_virt_base) / mem.page_size),
        .disable_execute = false,
    };

    invalidatePages();

    return &l4_table;
}

pub fn invalidatePages() void {
    setCr3(@intFromPtr(&l4_table) - mem.kernel_virt_base);
}

// TODO: when i get multiple cores i need to change this
/// only applies to this core
pub fn invalidatePage(page: *mem.Page) void {
    asm volatile (
        \\invlpg (%[addr])
        :
        : [addr] "r" (page),
        : .{ .memory = true });
}

fn setCr3(phys_addr: u64) void {
    asm volatile (
        \\movq %[addr], %cr3
        :
        : [addr] "r" (phys_addr),
    );
}
