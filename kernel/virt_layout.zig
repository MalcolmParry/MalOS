const std = @import("std");
const mem = @import("memory.zig");
const arch = @import("arch/arch.zig").current;

const big_align = arch.layout.big_align;
const page_size = mem.page_size;
const page_align = std.mem.Alignment.fromByteUnits(mem.page_size);

pub const RequestedRegion = struct {
    name: @EnumLiteral(),
    size: usize,
    alignment: std.mem.Alignment = big_align,
    min_pad: usize = page_size,
    maybe_addr: ?usize = null,
    sub_regions: []const RequestedRegion = &.{},
};

const Region = struct {
    name: @EnumLiteral(),
    base: usize,
    size: usize,
    slice: []u8,
    page_slice: []mem.Page,
};

const base_requested: []const RequestedRegion = &.{
    .{ .name = .direct_map, .size = arch.layout.direct_map_size },
    .{ .name = .kernel, .size = arch.layout.kernel_region_size, .maybe_addr = mem.kernel_virt_base },
    .{ .name = .kernel_stacks, .size = 1024 * 1024 * 1024 * 16 },
    .{ .name = .heap, .size = 1024 * 1024 * 1024 * 64 },
};

pub const regions = generateLayout(base_requested ++ arch.layout.requests, arch.layout.min_kernel_addr, arch.layout.kernel_space_size);

pub fn generateLayout(requested_regions: []const RequestedRegion, base: comptime_int, size: comptime_int) []const Region {
    var result: []const Region = &.{};

    for (requested_regions) |requested| if (requested.maybe_addr) |addr| {
        const len = page_align.forward(requested.size);
        result = result ++ [1]Region{.{
            .name = requested.name,
            .base = addr,
            .size = len,
            .slice = @as([*]u8, @ptrFromInt(addr))[0..len],
            .page_slice = @as([*]mem.Page, @ptrFromInt(addr))[0 .. len / page_size],
        }};
    };

    var bump: usize = base;
    for (requested_regions) |requested| {
        @setEvalBranchQuota(1_000_000);
        if (requested.maybe_addr != null) continue;
        bump = requested.alignment.forward(bump);
        const len = page_align.forward(requested.size);

        collision_loop: while (true) {
            const start = bump - requested.min_pad;
            const end = bump + len + requested.min_pad;

            for (result) |other| {
                const other_end = @as(comptime_int, other.base) + @as(comptime_int, other.size);
                if ((start >= other.base and start < other_end) or (other.base >= start and other.base < end)) {
                    bump = requested.alignment.forward(other_end + requested.min_pad);
                    continue :collision_loop;
                }
            }

            break;
        }

        if (bump + len > base + size) @compileError("region '" ++ @tagName(requested.name) ++ "' too big");
        result = result ++ [1]Region{.{
            .name = requested.name,
            .base = bump,
            .size = len,
            .slice = @as([*]u8, @ptrFromInt(bump))[0..len],
            .page_slice = @as([*]mem.Page, @ptrFromInt(bump))[0 .. len / page_size],
        }};

        result = result ++ generateLayout(requested.sub_regions, bump, len);
    }

    for (result, 0..) |a, i| {
        for (result[0..i]) |b| {
            if (a.name == b.name) @compileError(std.fmt.comptimePrint("2 regions named '{s}'", .{@tagName(a.name)}));
        }
    }

    return result;
}

pub fn get(comptime name: @EnumLiteral()) Region {
    inline for (regions) |region| {
        if (region.name == name) return region;
    }

    @compileError("cant find region '" ++ @tagName(name) ++ "'");
}
