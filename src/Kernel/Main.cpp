#include "Core.hpp"
#include "IO.hpp"
#include "Console.hpp"
#include "Heap.hpp"
#include "Utils.hpp"
#include "Interrupt.hpp"

namespace kernel {
	extern "C" void kernel_main() {
		cli();
		Console::Init();
		Heap::Init();
		InitInterrupts();
		sti();
	}
}
