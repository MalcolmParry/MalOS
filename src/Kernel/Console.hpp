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
	}

	using Color = _::Color;
 
	#pragma pack (1)
	struct Char {
		char c;
		u8 color;
	};
	
	#pragma pack (1)
	struct Line {
		Char c[80];

		Char& operator[](u8 i) {
			return c[i];
		}
	};

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
	void SetCursor(u8 x, u8 y);
	void UpdateCursor();
	void SetCursorShown(bool visible);
}