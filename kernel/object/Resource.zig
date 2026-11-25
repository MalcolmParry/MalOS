const std = @import("std");
const abi = @import("abi");
const gpa = @import("../mem/gpa.zig").allocator;
const Object = @import("Object.zig");
const Resource = @This();

obj: Object,
kind: abi.ResourceKind,
base: u64,
len: u64,

pub fn create(kind: abi.ResourceKind) !*Resource {
    const resource = try gpa.create(Resource);
    resource.* = .{
        .obj = .{ .kind = .resource, .ref_count = .init(1) },
        .kind = kind,
        .base = 0,
        .len = 0,
    };
    return resource;
}

pub fn destroy(resource: *Resource) void {
    gpa.destroy(resource);
}
