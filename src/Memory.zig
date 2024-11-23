const Arch = @import("Arch.zig");

pub const PAGE_SIZE = Arch.PAGE_SIZE;

pub const Range = struct {
    start: u64,
    size: u64,
};

pub const Map = struct {
    virt: Range,
    phys: ?Range,
};

pub const Module = struct {
    region: Range,
    name: []const u8,
};

//pub const MemProfile = struct {
//    kernel: Map,
//    pages: u64,
//    modules: []Module,
//};
