#pragma once

#include "Core.hpp"

namespace kernel::Console {
	namespace _ {
		enum Color {
			Black = 0,
			Blue = 1,
			Green = 2,
			Cyan = 3,
			Red = 4,
			Magenta = 5,
			Brown = 6,
			LightGrey = 7,
			DarkGrey = 8,
			LightBlue = 9,
			LightGreen = 10,
			LightCyan = 11,
			LightRed = 12,
			LightMagenta = 13,
			LightBrown = 14,
			White = 15,
		};

		enum CursorType {
			None,
			Block,
			Underline
		};
	}

	using Color = _::Color;
	using CursorType = _::CursorType;

	struct Char {
		char c;
		u8 color;
	} __attribute__((packed));
	
	struct Line {
		Char c[80];

		Char& operator[](u8 i) {
			return c[i];
		}
	} __attribute__((packed));

	Line* const videoMemory = (Line*) 0xb8000;
	constexpr u8 width = 80;
	constexpr u8 height = 25;

	extern u8 x;
	extern u8 y;
	extern u8 color;

	void Init();
	void ClearLine(u8 y);
	void Clear();
	void PutC(char c, bool updateCursor = true);
	void PutS(const char* str);
	void Newline(bool updateCursor = true);
	void Scroll();
	void UpdateCursor();
	void SetCursorType(CursorType type);
}
