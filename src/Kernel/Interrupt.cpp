#include "Interrupt.hpp"

#include "Console.hpp"
#include "Utils.hpp"

namespace kernel {
	struct IDT {
		u16 offset1;
		u16 selector;
		u8 ist;
		u8 typeAttibs;
		u16 offset2;
		u32 offset3;
		u32 zero;
	} __attribute__((packed));

	struct IDTR {
		u16 length;
		void* base;
	} __attribute__((packed));

	enum ISRType {
		InterruptGate = 0b1110,
		TrapGate = 0b1111
	};

	IDT idts[256];
	IDTR idtr;
	
	extern "C" void _irq_undef();

	void SetupIDT(IDT& idt, u64 isr, ISRType type, bool present) {
		idt.offset1 = isr & U16_MAX;
		idt.offset2 = (isr >> 16) & U16_MAX;
		idt.offset3 = (isr >> 32) & U32_MAX;
		idt.selector = 8;
		idt.ist = 0;
		idt.typeAttibs = type | ((present ? 1 : 0) << 7);
		idt.zero = 0;
	}

	void InitInterrupts() {
		for (u16 i = 0; i < 256; i++) {
			SetupIDT(idts[i], (u64) _irq_undef, InterruptGate, true);
		}
		
		idtr.length = sizeof(idts) - 1;
		idtr.base = idts;
		__asm volatile ("lidt %0" : : "m"(idtr));
	}

	extern "C" void irq_undef() {
		Console::PutS("Undefined interrupt.\n");
		hlt();
	}
}