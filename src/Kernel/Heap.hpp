#include "Core.hpp"

namespace kernel::Heap {
	void Init();
	void* Alloc(size_t size);
	void Free(void* ptr);
}

void* operator new(size_t size);
void* operator new[](size_t size);
void operator delete(void* ptr);
void operator delete[](void* ptr);
void operator delete(void* ptr, size_t size);
void operator delete[](void* ptr, size_t size);