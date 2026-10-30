const std = @import("std");

const Node = extern struct {
    name: [100]u8,
    mode: [8]u8,
    owner: [8]u8,
    group: [8]u8,
    size_oct_str: [12]u8,
    mtime_oct_str: [12]u8,
    checksum: [8]u8,
    type: u8,
    link_name: [100]u8,
    magic: [6]u8,
    version: [2]u8,
    owner_name: [32]u8,
    group_name: [32]u8,
    dev_major: [8]u8,
    dev_minor: [8]u8,
    name_prefix: [155]u8,
    pad: [12]u8,

    fn size(node: *const Node) usize {
        return readOctal(usize, &node.size_oct_str);
    }

    fn pathEql(node: *const Node, path: []const u8) bool {
        var name = std.mem.sliceTo(&node.name, 0);
        if (std.mem.startsWith(u8, name, "./")) name = name[2..];
        var prefix = std.mem.sliceTo(&node.name_prefix, 0);
        if (std.mem.startsWith(u8, prefix, "./")) prefix = prefix[2..];
        if (prefix.len == 0) return std.mem.eql(u8, name, path);

        if (path.len != prefix.len + name.len + 1) return false;
        if (!std.mem.eql(u8, path[0..prefix.len], prefix)) return false;
        if (!std.mem.eql(u8, path[prefix.len + 1 ..], name)) return false;
        if (path[prefix.len] != '/') return false;
        return true;
    }

    comptime {
        std.debug.assert(@sizeOf(Node) == 512);
    }
};

fn readOctal(T: type, str: []const u8) T {
    var val: T = 0;
    for (str) |c| switch (c) {
        '0'...'7' => {
            val *= 8;
            val += c - '0';
        },
        else => continue,
    };
    return val;
}

pub fn lookup(ustar: []const u8, path: []const u8) !?[]const u8 {
    const tar_end = ustar.ptr + ustar.len;

    var node: *const Node = @ptrCast(ustar);
    while (@intFromPtr(node) + 512 <= @intFromPtr(tar_end)) : ({
        node = @ptrCast(@as([*]const Node, @ptrCast(node)) + (node.size() + 511) / 512 + 1);
    }) {
        if (!std.mem.eql(u8, &node.magic, "ustar\x00")) return null;
        if (!node.pathEql(path)) continue;
        if (node.type != '0') return error.NotAFile;

        const data_ptr = @as([*]const u8, @ptrCast(node)) + 512;
        const data = data_ptr[0..node.size()];
        if (@intFromPtr(data.ptr + data.len) > @intFromPtr(tar_end)) return error.BadUstar;
        return data;
    }

    return null;
}
