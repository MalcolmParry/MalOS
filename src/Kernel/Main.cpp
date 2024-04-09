#include "Core.hpp"
#include "IO.hpp"
#include "Console.hpp"
#include "Heap.hpp"
#include "Utils.hpp"
#include "Interrupt.hpp"

namespace kernel {
	extern "C" void kernel_main() {
		Console::Init();
		Heap::Init();
		InitInterrupts();

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

		return;
	}
}