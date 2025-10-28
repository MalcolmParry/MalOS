const std = @import("std");
const gdt = @import("gdt.zig");
const mem = @import("../../memory.zig");
const vmm = @import("../../vmm.zig");
const arch = @import("arch.zig");
const PageAllocator = @import("../../PageAllocator.zig");

pub const tables = struct {
    pub const Index = u9;

    pub const Entry = packed struct {
        present: bool,
        writable: bool,
        user: bool,
        write_through: bool, // ?
        disable_cache: bool,
        // cpu sets this, should be set to false by default
        accessed: bool = false,
        available: bool = false,
        isHuge: bool,
        global: bool,
        available2: u3 = 0,
        address: u40, // address divided by 4096
        available3: u11 = 0,
        disable_execute: bool,

        const blank: Entry = .{
            .present = false,
            .writable = false,
            .user = false,
            .write_through = false,
            .disable_cache = false,
            .isHuge = false,
            .global = false,
            .address = 0,
            .disable_execute = false,
        };
    };

    const reserve = struct {
        var l2: [2]?*align(mem.page_size) L2 = @splat(null);
        var l1: [2]?*align(mem.page_size) L1 = @splat(null);
        var allocating: bool = false;

        fn allocateSlice(T: type, slice: []?*align(mem.page_size) T, alloc: std.mem.Allocator) !void {
            for (slice) |*table| {
                if (table.* != null) continue;

                table.* = &(try alloc.alignedAlloc(T, .fromByteUnits(mem.page_size), 1))[0];
            }
        }

        fn allocate(alloc: std.mem.Allocator) !void {
            if (allocating) return;
            allocating = true;

            try allocateSlice(L1, &l1, alloc);
            try allocateSlice(L2, &l2, alloc);

            allocating = false;
        }

        fn getTable(T: type) *align(mem.page_size) T {
            const slice: []?*align(mem.page_size) T = switch (T) {
                L2 => &l2,
                L1 => &l1,
                else => @panic("wrong type"),
            };

            for (slice) |*table| {
                if (table.*) |x| {
                    table.* = null;
                    return x;
                }
            }

            @panic("no table reserved");
        }
    };

    fn getOrCreateTable(l4: *L4, T: type, table: *T, index: usize) !*GetLowerType(T) {
        const lowerT = GetLowerType(T);

        if (table.tables[index]) |lower|
            return lower;

        const lower = reserve.getTable(lowerT);

        table.tables[index] = lower;
        table.entries[index] = .{
            .present = true,
            .writable = true,
            .user = false,
            .write_through = false,
            .disable_cache = false,
            .isHuge = false,
            .global = false,
            .address = @intCast(@intFromPtr(l4.getPhysAddrFromVirt(@ptrCast(lower))) / mem.page_size),
            .disable_execute = false,
        };

        initEmpty(lower);
        return lower;
    }

    // each entry is 512gb
    pub const L4 = extern struct {
        entries: [512]Entry,
        tables: [512]?*L3,

        pub fn mapPage(this: *L4, phys: mem.PhysPagePtr, virt: mem.PagePtr, page_flags: vmm.PageFlags, can_overwrite: bool, alloc: std.mem.Allocator) !void {
            const indices = getIndicesFromVirtAddr(virt);

            const l4 = this;
            const l3 = try getOrCreateTable(l4, L4, l4, indices[3]);
            const l2 = try getOrCreateTable(l4, L3, l3, indices[2]);
            const l1 = try getOrCreateTable(l4, L2, l2, indices[1]);
            try reserve.allocate(alloc);

            if (!can_overwrite and l1[indices[0]].present)
                return error.Overwrite;

            l1[indices[0]] = .{
                .present = page_flags.present,
                .writable = page_flags.writable,
                .user = !page_flags.kernel_only,
                .write_through = page_flags.cache_mode == .write_through,
                .disable_cache = page_flags.cache_mode == .disabled,
                .isHuge = false,
                .global = page_flags.global,
                .address = @intCast(@intFromPtr(phys) / mem.page_size),
                .disable_execute = !page_flags.executable,
            };
        }

        pub fn getPhysAddrFromVirt(this: *@This(), virt: mem.PagePtr) mem.PhysPagePtr {
            const indices = getIndicesFromVirtAddr(virt);

            const l4 = this;
            const l3 = l4.tables[indices[3]] orelse @panic("not mapped");
            const l2 = l3.tables[indices[2]] orelse @panic("not mapped");
            if (l2.entries[indices[1]].present and l2.entries[indices[1]].isHuge)
                return @ptrFromInt((l2.entries[indices[1]].address + indices[0]) * mem.page_size);

            const l1 = l2.tables[indices[1]] orelse @panic("not mapped");
            if (!l1[indices[0]].present) @panic("not mapped");
            return @ptrFromInt(l1[indices[0]].address * mem.page_size);
        }

        pub fn isAvailable(this: *@This(), page: mem.PagePtr) bool {
            const indices = getIndicesFromVirtAddr(page);
            const l4 = this;
            const l3 = l4.tables[indices[3]] orelse return true;
            const l2 = l3.tables[indices[2]] orelse return true;
            if (l2.entries[1].present and l2.entries[1].isHuge)
                return false;

            const l1 = l2.tables[indices[1]] orelse return true;
            return !l1[indices[0]].present;
        }

        pub fn isRegionAvailable(this: *@This(), region: mem.PageSlice) bool {
            for (region) |*page| {
                if (!this.isAvailable(page)) return false;
            }

            return true;
        }

        pub fn clearEntry(this: *@This(), virt: mem.PagePtr) !void {
            const indices = getIndicesFromVirtAddr(virt);

            const l4 = this;
            const l3 = l4.tables[indices[3]] orelse @panic("not mapped");
            const l2 = l3.tables[indices[2]] orelse @panic("not mapped");
            if (l2.entries[indices[1]].present and l2.entries[indices[1]].isHuge)
                l2.entries[indices[1]] = Entry.blank;

            const l1 = l2.tables[indices[1]] orelse @panic("not mapped");
            if (!l1[indices[0]].present) @panic("not mapped");

            l1[indices[0]] = Entry.blank;
            invalidatePage(virt);
        }
    };

    // each entry is 1gb
    const L3 = extern struct { entries: [512]Entry, tables: [512]?*L2 };

    // each entry is 2mb
    const L2 = extern struct { entries: [512]Entry, tables: [512]?*L1 };

    // each entry is 4kb
    const L1 = [512]Entry;

    fn getVirtAddrFromindices(l4: Index, l3: Index, l2: Index, l1: Index) mem.PagePtr {
        const ul4: usize = l4;
        const ul3: usize = l3;
        const ul2: usize = l2;
        const ul1: usize = l1;

        const addr: usize = (ul1 << 12) | (ul2 << 21) | (ul3 << 30) | (ul4 << 39);
        const mask: usize = @truncate(std.math.boolMask(usize, true) << 48);
        const full: usize = addr | if (l4 & (1 << 8) > 1) mask else 0;
        return @ptrFromInt(full);
    }

    fn getIndicesFromVirtAddr(addr: mem.PagePtr) [4]Index {
        const addrI = @intFromPtr(addr);
        const l4 = (addrI >> 39) & 0x1ff;
        const l3 = (addrI >> 30) & 0x1ff;
        const l2 = (addrI >> 21) & 0x1ff;
        const l1 = (addrI >> 12) & 0x1ff;
        return .{
            @intCast(l1),
            @intCast(l2),
            @intCast(l3),
            @intCast(l4),
        };
    }

    fn initEmpty(table: anytype) void {
        switch (@typeInfo(@TypeOf(table)).pointer.child) {
            L4, L3, L2 => {
                @memset(&table.entries, Entry.blank);
                @memset(&table.tables, null);
            },
            L1 => @memset(table, Entry.blank),
            else => @compileError("wrong type"),
        }
    }

    fn GetLowerType(T: type) type {
        return switch (T) {
            L4 => L3,
            L3 => L2,
            L2 => L1,
            else => @compileError("wrong type"),
        };
    }
};

const page_tables_l3_index = 510;
const page_tables_start = tables.getVirtAddrFromindices(511, page_tables_l3_index, 0, 0);
pub const heap_range = @as(mem.PageManyPtr, @ptrCast(tables.getVirtAddrFromindices(511, 0, 0, 0)))[0 .. 512 * 512 * 510];
pub var table_allocator: PageAllocator = undefined;

var l4_table: tables.L4 align(4096) = undefined;
var l3_kernel_table: tables.L3 align(4096) = undefined;
var l2_kernel_table: tables.L2 align(4096) = undefined;

comptime {
    @export(&l4_table.entries, .{ .name = "page_table_l4_virt" });
    @export(&l3_kernel_table.entries, .{ .name = "page_table_l3_virt" });
    @export(&l2_kernel_table.entries, .{ .name = "page_table_l2_virt" });
}

var l2_page_table_starter: tables.L2 align(4096) = undefined;
var l1_page_table_starter: tables.L1 align(4096) = undefined;

fn enableExecuteDisable() void {
    const msr = 0xc000_0080;
    const old = arch.readMSR(msr);
    arch.writeMSR(msr, old | (1 << 11));
}

pub fn init() *tables.L4 {
    enableExecuteDisable();
    gdt.init();

    @memset(l4_table.entries[0..511], tables.Entry.blank);
    @memset(l3_kernel_table.entries[0..511], tables.Entry.blank);
    @memset(&l4_table.tables, null);
    @memset(&l3_kernel_table.tables, null);
    @memset(&l2_kernel_table.tables, null);
    l4_table.tables[511] = &l3_kernel_table;
    l3_kernel_table.tables[511] = &l2_kernel_table;

    tables.initEmpty(&l2_page_table_starter);
    tables.initEmpty(&l1_page_table_starter);

    l2_page_table_starter.tables[0] = &l1_page_table_starter;
    l2_page_table_starter.entries[0] = .{
        .present = true,
        .writable = true,
        .user = false,
        .write_through = false,
        .disable_cache = false,
        .isHuge = false,
        .global = false,
        .address = @intCast((@intFromPtr(&l1_page_table_starter) - mem.kernel_virt_base) / mem.page_size),
        .disable_execute = false,
    };

    l3_kernel_table.tables[page_tables_l3_index] = &l2_page_table_starter;
    l3_kernel_table.entries[page_tables_l3_index] = .{
        .present = true,
        .writable = true,
        .user = false,
        .write_through = false,
        .disable_cache = false,
        .isHuge = false,
        .global = false,
        .address = @intCast((@intFromPtr(&l2_page_table_starter.entries) - mem.kernel_virt_base) / mem.page_size),
        .disable_execute = false,
    };

    invalidatePages();

    const page_table_many_ptr: mem.PageManyPtr = @ptrCast(page_tables_start);
    table_allocator = .init(&l4_table, page_table_many_ptr[0 .. 512 * 512]);
    tables.reserve.allocate(table_allocator.allocator()) catch @panic("cant allocate tables");

    return &l4_table;
}

pub fn invalidatePages() void {
    setCr3(@intFromPtr(&l4_table) - mem.kernel_virt_base);
}

pub fn invalidatePage(page: mem.PagePtr) void {
    asm volatile (
        \\invlpg (%[addr])
        :
        : [addr] "r" (page),
        : .{ .memory = true });
}

fn setCr3(physAddr: u64) void {
    asm volatile (
        \\movq %[addr], %cr3
        :
        : [addr] "r" (physAddr),
    );
}
