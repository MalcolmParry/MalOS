#pragma once

#include "Core.hpp"

extern "C" {
	void outb(u16 port, u8 data);
	u8 inb(u16 port);
}