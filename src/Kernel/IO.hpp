#pragma once

#include "Core.hpp"

#define outb(port, data) __asm volatile ("out %w1, %b0" : : "a"(data), "Nd"(port) : "memory")

extern "C" {
	//void outb(u16 port, u8 data);
	u8 inb(u16 port);
}