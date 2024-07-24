#pragma once

#include "Core.hpp"

#define cli() __asm volatile("cli")
#define sti() __asm volatile("sti")
#define outb(port, data) __asm volatile("out %w1, %b0" : : "a"(data), "Nd"(port) : "memory")

u8 inb(u16 port);
