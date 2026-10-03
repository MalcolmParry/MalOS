const std = @import("std");
const assert = std.debug.assert;
const TextGrid = @This();

width: u16,
height: u16,
put_ptr: *const fn (tg: *TextGrid, x: u16, y: u16, cell: Cell) void,
fill_ptr: *const fn (tg: *TextGrid, x: u16, y: u16, len: u16, cell: Cell) void,
scroll_ptr: *const fn (tg: *TextGrid, line_count: u16, blank: Cell) void,
set_cursor_ptr: *const fn (tg: *TextGrid, x: u16, y: u16) void,
set_cursor_shape_ptr: *const fn (tg: *TextGrid, shape: CursorShape) void,

pub const Color = enum(u4) {
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
};

pub const CursorShape = enum {
    none,
    block,
    underline,
};

pub const Cell = struct {
    char: u8,
    fg: Color,
    bg: Color,
};

pub fn put(tg: *TextGrid, x: u16, y: u16, cell: Cell) void {
    assert(x < tg.width and y < tg.height);
    tg.put_ptr(tg, x, y, cell);
}

/// must stay in 1 row
pub fn fill(tg: *TextGrid, x: u16, y: u16, len: u16, cell: Cell) void {
    assert(x + len <= tg.width and y < tg.height);
    tg.fill_ptr(tg, x, y, len, cell);
}

pub fn scroll(tg: *TextGrid, line_count: u16, blank: Cell) void {
    assert(line_count < tg.height);
    tg.scroll_ptr(tg, line_count, blank);
}

pub fn setCursor(tg: *TextGrid, x: u16, y: u16) void {
    assert(x < tg.width and y < tg.height);
    tg.set_cursor_ptr(tg, x, y);
}

pub fn setCursorShape(tg: *TextGrid, shape: CursorShape) void {
    tg.set_cursor_shape_ptr(tg, shape);
}
