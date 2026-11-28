const std = @import("std");
const syscall = @import("syscall.zig");

pub const Header = extern struct {
    vmar: syscall.Handle,
    klog: syscall.Handle,
    initrd: syscall.Handle,
    resource_offset: u32,
    resource_count: u32,
};

pub const Resource = extern struct {
    handle: syscall.Handle,
    kind: syscall.ResourceKind,
    base: u64,
    len: u64,
};
