const std = @import("std");
const mem = @import("../../memory.zig");
const arch = @import("../../arch/arch.zig").current;
const PageAllocator = @import("../../heap/PageAllocator.zig");
const BootInfo = @import("../../BootInfo.zig");

const Color = enum(u4) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    purple = 5,
    brown = 6,
    gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_purple = 13,
    yellow = 14,
    white = 15,

    fn fromAnsi(ansi: u32) Color {
        return switch (ansi) {
            0 => .black,
            1 => .red,
            2 => .green,
            3 => .yellow,
            4 => .blue,
            5 => .purple,
            6 => .cyan,
            7 => .white,
            else => unreachable,
        };
    }
};

const CursorType = enum {
    none,
    block,
    underline,
};

const Char = packed struct {
    char: u8,
    fg: Color,
    bg: Color,
};

const default_fg: Color = .white;
const default_bg: Color = .black;

const State = struct {
    chars: usize,
    width: u16,
    height: u16,
    pitch: u32,

    x: u16 = 0,
    y: u16 = 0,
    fg: Color = default_fg,
    bg: Color = default_bg,

    escaped: EscapeState = .normal,
    escaped_num: u16 = 0,
};

const EscapeState = enum {
    normal,
    esc,
    esc_lbracket,
};

pub fn init(info: BootInfo.VgaTextInfo) !Writer {
    const offset = info.phys_addr % mem.page_size;
    const size = @as(usize, info.pitch) * info.height;
    const page_count = (size + offset + mem.page_size - 1) / mem.page_size;
    const phys_pages = @as([*]mem.PhysPage, @ptrFromInt(info.phys_addr - offset))[0..page_count];

    const pages = try PageAllocator.global.map(phys_pages, .{
        .cache_mode = .write_through,
        .global = true,
        .executable = false,
        .user = false,
        .writable = true,
    });
    errdefer PageAllocator.global.free(pages);

    var state: State = .{
        .chars = @intFromPtr(pages.ptr) + offset,
        .width = info.width,
        .height = info.height,
        .pitch = info.pitch,
    };

    clear(&state);
    return .{ .state = state };
}

fn print(state: *State, str: []const u8) void {
    for (str) |c| {
        switch (state.escaped) {
            .normal => switch (c) {
                32...126 => {
                    putChar(state.*, state.x, state.y, c);
                    advance(state);
                },
                '\r' => state.x = 0,
                '\n' => {
                    state.x = 0;
                    state.y += 1;
                    if (state.y >= state.height) {
                        state.y = state.height - 1;
                        scroll(state.*);
                    }
                },
                '\x1b' => state.escaped = .esc,
                else => {},
            },
            .esc => switch (c) {
                '[' => {
                    state.escaped = .esc_lbracket;
                    state.escaped_num = 0;
                },
                else => state.escaped = .normal,
            },
            .esc_lbracket => switch (c) {
                '0'...'9' => {
                    state.escaped_num *|= 10;
                    state.escaped_num +|= c - '0';
                    state.escaped_num = @min(state.escaped_num, 9999);
                },
                'm' => {
                    switch (state.escaped_num) {
                        0 => reset(state),
                        30...37 => state.fg = .fromAnsi(state.escaped_num - 30),
                        40...47 => state.bg = .fromAnsi(state.escaped_num - 40),
                        39 => state.fg = default_fg,
                        49 => state.bg = default_bg,
                        else => {},
                    }

                    state.escaped = .normal;
                },
                'G' => {
                    state.x = @min(state.width - 1, state.escaped_num - 1);
                    state.escaped = .normal;
                },
                else => {
                    state.escaped = .normal;
                },
            },
        }
    }
}

fn advance(state: *State) void {
    state.x += 1;
    if (state.x >= state.width) {
        state.x = 0;
        state.y += 1;
    }

    if (state.y >= state.height) {
        state.y = state.height - 1;
        scroll(state.*);
    }
}

fn scroll(state: State) void {
    for (0..state.height - 1) |y| {
        const upper = getRow(state, @intCast(y));
        const lower = getRow(state, @intCast(y + 1));
        @memcpy(upper, lower);
    }

    clearLine(state, state.height - 1);
}

fn clearLine(state: State, y: u16) void {
    @memset(getRow(state, y), .{
        .char = ' ',
        .fg = state.fg,
        .bg = state.bg,
    });
}

fn clear(state: *State) void {
    reset(state);
    state.x = 0;
    state.y = 0;

    for (0..state.height) |y| {
        clearLine(state.*, @intCast(y));
    }
}

fn reset(state: *State) void {
    state.fg = default_fg;
    state.bg = default_bg;
    state.escaped = .normal;
}

fn getRow(state: State, y: u16) []align(1) Char {
    const char_ptr: [*]align(1) Char = @ptrFromInt(state.chars + @as(usize, state.pitch) * y);
    return char_ptr[0..state.width];
}

fn putChar(state: State, x: u16, y: u16, c: u8) void {
    getRow(state, y)[x] = .{
        .char = c,
        .fg = state.fg,
        .bg = state.bg,
    };
}

fn setCursorType(t: CursorType) void {
    if (t == .none) {
        arch.outb(0x3d4, 0x0a);
        arch.outb(0x3d5, 0x20);
        return;
    }

    const startScanline: u8 = if (t == .block) 0 else 14;

    arch.outb(0x3d4, 0x0a);
    arch.outb(0x3d5, (arch.in(u8, 0x3d5) & 0xc0) | startScanline);

    arch.outb(0x3d4, 0x0b);
    arch.outb(0x3d5, (arch.in(u8, 0x3d5) & 0xe0) | 15);
}

fn setCursorPos(state: State, x: u8, y: u8) void {
    const pos: u16 = @as(u16, @intCast(state.width)) * y + x;

    arch.outb(0x3d4, 0x0f);
    arch.outb(0x3d5, @truncate(pos));
    arch.outb(0x3d4, 0x0e);
    arch.outb(0x3d5, @truncate(pos >> 8));
}

pub const Writer = struct {
    interface: std.Io.Writer = .{
        .buffer = &.{},
        .vtable = &.{ .drain = &drain },
    },
    state: State,

    fn drain(this: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        const writer: *Writer = @fieldParentPtr("interface", this);
        const state = &writer.state;

        print(state, this.buffer[0..this.end]);
        this.end = 0;
        var written: usize = 0;

        for (data[0 .. data.len - 1]) |x| {
            print(state, x);
            written += x.len;
        }

        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            print(state, pattern);
            written += pattern.len;
        }

        setCursorPos(state.*, @intCast(state.x), @intCast(state.y));
        return written;
    }
};
