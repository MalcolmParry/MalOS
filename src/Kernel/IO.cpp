#include "IO.hpp"

u8 inb(u16 port) {
	u8 ret;
	__asm volatile ("inb %b0, %w1" : "=a"(ret) : "Nd"(port) : "memory");
	return ret;
}