#include "Console.hpp"
#include "IO.hpp"

namespace kernel::Console {
	u8 x;
	u8 y;
	u8 color;

	void Init() {
		color = Color::Green | Color::Black << 4;
		x = 0;
		y = 0;
		UpdateCursor();
		Clear();
		SetCursorType(CursorType::Underline);
	}
	
	void ClearLine(u8 y) {
		for (u8 x = 0; x < width; x++) {
			videoMemory[y][x] = { ' ', color };
		}
	}

	void Clear() {
		for (u8 y = 0; y < height; y++) {
			ClearLine(y);
		}
	}

	void PutC(char c, bool updateCursor) {
		if (c == '\n') {
			Newline();
			return;
		}

		videoMemory[y][x] = { c, color };
		x++;

		if (x >= width) {
			Newline(updateCursor);
			return;
		}

		if (updateCursor) {
			UpdateCursor();
		}
	}

	void PutS(const char* str) {
		for (u32 i = 0; str[i] != '\0'; i++) {
			PutC(str[i], false);
		}

		UpdateCursor();
	}

	void Newline(bool updateCursor) {
		x = 0;
		y++;
		if (y >= height) {
			Scroll();
		}

		if (updateCursor) {
			UpdateCursor();
		}
	}

	void Scroll() {
		for (u8 y = 1; y < height; y++) {
			videoMemory[y] = videoMemory[y - 1];
		}

		ClearLine(height - 1);
	}
	
	void UpdateCursor() {
		u16 pos = y * width + x;

		outb(0x3d4, 0x0f);
		outb(0x3d5, (u8) (pos & 0xff));
		outb(0x3d4, 0x0e);
		outb(0x3d5, (u8) ((pos >> 8) & 0xff));
	}
	
	void SetCursorType(CursorType type) {
		if (type == CursorType::None) {
			outb(0x3d4, 0x0a);
			outb(0x3d5, 0x20);
			return;
		}

		u8 startScanline = (type == CursorType::Block) ? 0 : 14;
		
		outb(0x3d4, 0x0a);
		outb(0x3d5, (inb(0x3d5) & 0xc0) | startScanline);

		outb(0x3d4, 0x0b);
		outb(0x3d5, (inb(0x3d5) & 0xe0) | 15);
	}
}
