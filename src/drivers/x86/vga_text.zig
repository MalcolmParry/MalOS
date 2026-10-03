const std = @import("std");
const mem = @import("../../memory.zig");
const TextGrid = @import("../../tty/TextGrid.zig");
const arch = @import("../../arch/arch.zig").current;

const width = 80;
const height = 25;
const char_count = width * height;

const video_memory: *[char_count]Char = @ptrFromInt(0xb8000 + mem.kernel_virt_base);
var read_buffer: [char_count]Char = undefined;
pub var tg: TextGrid = .{
    .width = width,
    .height = height,
    .put_ptr = &put,
    .fill_ptr = &fill,
    .scroll_ptr = &scroll,
    .set_cursor_ptr = &setCursor,
    .set_cursor_shape_ptr = &setCursorShape,
};

const Char = packed struct {
    char: u8,
    fg: TextGrid.Color,
    bg: TextGrid.Color,

    fn fromCell(cell: TextGrid.Cell) Char {
        return .{
            .char = cell.char,
            .fg = cell.fg,
            .bg = cell.bg,
        };
    }
};

pub fn init() void {
    const blank: Char = .{ .char = ' ', .fg = .white, .bg = .black };
    @memset(video_memory, blank);
    @memset(&read_buffer, blank);
}

fn put(_: *TextGrid, x: u16, y: u16, cell: TextGrid.Cell) void {
    const c: Char = .fromCell(cell);
    const i = @as(usize, y) * width + x;
    video_memory[i] = c;
    read_buffer[i] = c;
}

fn fill(_: *TextGrid, x: u16, y: u16, len: u16, cell: TextGrid.Cell) void {
    const c: Char = .fromCell(cell);
    const i = @as(usize, y) * width + x;
    @memset(video_memory[i..][0..len], c);
    @memset(read_buffer[i..][0..len], c);
}

fn scroll(_: *TextGrid, line_count: u16, blank: TextGrid.Cell) void {
    const shift = @as(usize, line_count) * width;
    const kept = width * height - shift;

    @memmove(read_buffer[0..kept], read_buffer[shift..]);
    @memset(read_buffer[kept..], .fromCell(blank));
    @memcpy(video_memory, &read_buffer);
}

fn setCursor(_: *TextGrid, x: u16, y: u16) void {
    const pos = y * width + x;

    arch.outb(0x3d4, 0x0f);
    arch.outb(0x3d5, @truncate(pos));
    arch.outb(0x3d4, 0x0e);
    arch.outb(0x3d5, @truncate(pos >> 8));
}

fn setCursorShape(_: *TextGrid, shape: TextGrid.CursorShape) void {
    const start_scanline: u8 = switch (shape) {
        .block => 0,
        .underline => 14,
        .none => {
            arch.outb(0x3d4, 0x0a);
            arch.outb(0x3d5, 0x20);
            return;
        },
    };

    arch.outb(0x3d4, 0x0a);
    arch.outb(0x3d5, (arch.in(u8, 0x3d5) & 0xc0) | start_scanline);

    arch.outb(0x3d4, 0x0b);
    arch.outb(0x3d5, (arch.in(u8, 0x3d5) & 0xe0) | 15);
}
