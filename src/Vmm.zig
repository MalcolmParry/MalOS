const std = @import("std");
const arch = @import("arch.zig");
const mem = @import("memory.zig");
const direct_map = @import("heap/direct_map.zig");
const Vmm = @This();

pub const PageFlags = packed struct {
    const CacheMode = enum(u2) {
        full,
        // for memory that is read by hardware
        write_through,
        // for io
        disabled,
    };

    cache_mode: CacheMode,
    writable: bool,
    executable: bool,
    user: bool,
    global: bool,
};

first_node: ?*Node,
node_pool: std.heap.MemoryPool(Node),

const Node = struct {
    next: ?*Node,
    range: []mem.Page,
};

pub fn init(available_range: []mem.Page) !Vmm {
    var node_pool: std.heap.MemoryPool(Node) = .empty;
    const first_node = try node_pool.create(direct_map.page_alloc);
    first_node.* = .{
        .next = null,
        .range = available_range,
    };

    return .{
        .first_node = first_node,
        .node_pool = node_pool,
    };
}

pub fn deinit(vmm: *Vmm) void {
    vmm.node_pool.deinit(direct_map.page_alloc);
    vmm.first_node = null;
}

pub fn reserve(vmm: *Vmm, page_count: usize) ![]mem.Page {
    var last_node_ptr: *?*Node = &vmm.first_node;
    var maybe_node = vmm.first_node;

    while (maybe_node) |node| : ({
        last_node_ptr = &node.next;
        maybe_node = node.next;
    }) {
        if (node.range.len < page_count) continue;
        const result = node.range[0..page_count];

        if (node.range.len == page_count) {
            last_node_ptr.* = node.next;
            vmm.node_pool.destroy(node);
            return result;
        }

        node.range = node.range[page_count..];
        return result;
    }

    return error.NoAvailableVirtualAddressSpace;
}

pub fn unreserve(vmm: *Vmm, pages: []mem.Page) !void {
    var last_node_ptr: *?*Node = &vmm.first_node;
    var maybe_node = vmm.first_node;

    while (maybe_node) |node| : ({
        last_node_ptr = &node.next;
        maybe_node = node.next;
    }) {
        if (pages.ptr + pages.len == node.range.ptr) {
            node.range = pages.ptr[0 .. pages.len + node.range.len];
            return;
        }

        if (node.range.ptr + node.range.len == pages.ptr) {
            node.range = node.range.ptr[0 .. pages.len + node.range.len];

            if (node.next) |next| {
                if (node.range.ptr + node.range.len == next.range.ptr) {
                    node.range = node.range.ptr[0 .. node.range.len + next.range.len];
                    node.next = next.next;
                    vmm.node_pool.destroy(next);
                }
            }

            return;
        }

        if (@intFromPtr(pages.ptr) < @intFromPtr(node.range.ptr)) {
            const new = try vmm.node_pool.create(direct_map.page_alloc);
            new.* = .{
                .next = node,
                .range = pages,
            };

            last_node_ptr.* = new;
            return;
        }
    }

    const new = try vmm.node_pool.create(direct_map.page_alloc);
    new.* = .{
        .next = null,
        .range = pages,
    };

    last_node_ptr.* = new;
}
