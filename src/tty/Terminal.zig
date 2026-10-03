const std = @import("std");
const TextGrid = @import("TextGrid.zig");
const Terminal = @This();

tg: *TextGrid,
x: u16 = 0,
y: u16 = 0,
fg: TextGrid.Color = default_fg,
bg: TextGrid.Color = default_bg,
escaped: EscapeState = .normal,
escape_nums: [16]u16 = @splat(0),
escape_num_i: u8 = 0,

const default_fg: TextGrid.Color = .white;
const default_bg: TextGrid.Color = .black;
const tab_len = 8;
const EscapeState = enum {
    normal,
    esc,
    esc_lbracket,
};

fn print(term: *Terminal, str: []const u8) void {
    for (str) |c| switch (term.escaped) {
        .normal => switch (c) {
            32...126 => {
                term.tg.put(term.x, term.y, .{
                    .char = c,
                    .fg = term.fg,
                    .bg = term.bg,
                });

                term.x += 1;
                if (term.x >= term.tg.width) {
                    term.x = 0;
                    term.y += 1;

                    if (term.y >= term.tg.height) {
                        term.y = term.tg.height - 1;
                        term.tg.scroll(1, term.blankCell());
                    }
                }
            },
            '\t' => term.x = @min(term.tg.width - 1, (term.x + tab_len) / tab_len * tab_len),
            '\x08' => term.x -|= 1,
            '\r' => term.x = 0,
            '\n' => {
                // TODO: move this into output processing layer
                term.x = 0;
                term.y += 1;

                if (term.y >= term.tg.height) {
                    term.y = term.tg.height - 1;
                    term.tg.scroll(1, term.blankCell());
                }
            },
            0x1b => term.escaped = .esc,
            else => {},
        },
        .esc => switch (c) {
            '[' => {
                @memset(&term.escape_nums, 0);
                term.escape_num_i = 0;
                term.escaped = .esc_lbracket;
            },
            else => term.escaped = .normal,
        },
        .esc_lbracket => switch (c) {
            '0'...'9' => {
                const n = &term.escape_nums[term.escape_num_i];
                n.* *|= 10;
                n.* +|= c - '0';
                n.* = @min(n.*, 9999);
            },
            ';' => if (term.escape_num_i < term.escape_nums.len - 1) {
                term.escape_num_i += 1;
            },
            0x40...0x7e => {
                term.handleCsi(c);
                term.escaped = .normal;
            },
            0x1b => term.escaped = .esc,
            else => {},
        },
    };
}

fn handleCsi(term: *Terminal, c: u8) void {
    switch (c) {
        'm' => for (0..term.escape_num_i + 1) |i| {
            const n = term.escape_nums[i];
            switch (term.escape_nums[i]) {
                0 => {
                    term.fg = default_fg;
                    term.bg = default_bg;
                },
                30...37 => term.fg = colorFromAnsi(n - 30),
                40...47 => term.bg = colorFromAnsi(n - 40),
                90...97 => term.fg = brighten(colorFromAnsi(n - 90)),
                100...107 => term.bg = brighten(colorFromAnsi(n - 100)),
                39 => term.fg = default_fg,
                49 => term.bg = default_bg,
                else => {},
            }
        },
        'G' => term.x = @min(term.tg.width - 1, @max(term.escape_nums[0], 1) - 1),
        'H' => {
            term.y = @min(@max(1, term.escape_nums[0]), term.tg.height) - 1;
            term.x = @min(@max(1, term.escape_nums[1]), term.tg.width) - 1;
        },
        'J' => switch (term.escape_nums[0]) {
            2 => for (0..term.tg.height) |y| {
                term.tg.fill(0, @intCast(y), term.tg.width, term.blankCell());
            },
            else => {},
        },
        else => {},
    }
}

fn blankCell(term: *const Terminal) TextGrid.Cell {
    return .{
        .char = ' ',
        .fg = term.fg,
        .bg = term.bg,
    };
}

fn colorFromAnsi(ansi: u16) TextGrid.Color {
    return switch (ansi) {
        0 => .black,
        1 => .red,
        2 => .green,
        3 => .brown,
        4 => .blue,
        5 => .purple,
        6 => .cyan,
        7 => .gray,
        else => unreachable,
    };
}

fn brighten(color: TextGrid.Color) TextGrid.Color {
    return @enumFromInt(@intFromEnum(color) | 8);
}

pub fn writer(term: *Terminal, buffer: []u8) Writer {
    return .{
        .term = term,
        .w = .{
            .buffer = buffer,
            .vtable = &.{
                .drain = &Writer.drain,
            },
        },
    };
}

pub const Writer = struct {
    w: std.Io.Writer,
    term: *Terminal,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const w_obj: *Writer = @fieldParentPtr("w", w);
        const term = w_obj.term;

        term.print(w.buffered());
        w.end = 0;
        var written: usize = 0;

        for (data[0 .. data.len - 1]) |str| {
            term.print(str);
            written += str.len;
        }

        const pattern = data[data.len - 1];
        written += pattern.len * splat;
        for (0..splat) |_| {
            term.print(pattern);
        }

        term.tg.setCursor(term.x, term.y);
        return written;
    }
};
