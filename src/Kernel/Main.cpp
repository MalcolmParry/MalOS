#include "Core.hpp"

struct ConsoleChar {
	char c;
	u8 color;
};

ConsoleChar* buffer = (ConsoleChar*) 0xb8000;

void puts(const char* str) {
	for (u32 i = 0; str[i] != '\0'; i++) {
		buffer[i] = { str[i], 0x02 };
	}
}

extern "C" void kernel_main() {
	puts("hello world!");
	buffer[160] = { (char) k::error, 0x02 };

	return;
}