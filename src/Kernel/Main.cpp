#include "Core.hpp"
#include "IO.hpp"
#include "Console.hpp"
#include "Heap.hpp"
#include "Utils.hpp"

namespace kernel {
	#if 0
	char* u32_to_str(u32 value) {
		char str[11] { 0 };

		for (u8 i = 0; value != 0; i++) {
			u32 rem = value % 10;
			str[i] = rem + '0';
			value = value / 10;
		}

		return str;
	}

	void strcpy(char* dst, const char* src) {
		u32 i = 0;
		for (; src[i] != '\0'; i++) {
			dst[i] = src[i];
		}

		dst[i + 1] = '\0';
	}

	struct IDT {
		u16 offset1;
		u16 selector;
		u8 ist;
		u8 typeAttibs;
		u16 offset2;
		u32 offset3;
		u32 zero;
	};

	IDT idts[256];

	extern "C" void isr();

	void SetupIDT(IDT& idt, u64 isr, u16 type) {
		idt.offset1 = isr & U16_MAX;
		idt.offset2 = (isr << 16) & U16_MAX;
		idt.offset3 = (isr << 32) & U32_MAX;
		idt.selector = 8;
		idt.ist = 0;

	}

	void SetupIDTs() {
		u64 pIsr = (u64) isr;

		for (u16 i = 0; i < 256; i++) {
			idt64[i].offset1 = pIsr & U16_MAX;
			idt64[i].offset2 = (pIsr << 16) & U16_MAX;
			idt64[i].offset3 = (pIsr << 32) & U32_MAX;
			idt64[i].selector = 8;
			idt64[i].ist = 0;
			idt64[i].typeAttibs = 
		}
	}
	#endif

	extern "C" void kernel_main() {
		Console::Init();
		Heap::Init();
		//SetupIDTs();

		type_t u32_id = ctypeid(u32);


		const char src[] = "Hello dynamic allocation!\n";
		const char src2[] = "Hello dynamic allocation 2!\n";
		char* dst = new char[sizeof(src)];
		char* dst2 = new char[sizeof(src2)];
		strcpy(dst, src);
		strcpy(dst2, src2);
		Console::PutS(dst);
		Console::PutS(dst2);
		delete[] dst2;
		delete[] dst;

		char buf[20] { 0 };
		u64tostr(buf, u32_id, 10);
		
		Console::PutS(buf);
		Console::Newline();

		return;
	}
}