#pragma once

#include "Core.hpp"
#include "Utils.hpp"

namespace kernel::Heap {
	void Init();
	void* Alloc(u64 size);
	void* Realloc(void* ptr, u64 size);
	void Free(void* ptr);
}

void* operator new(size_t size);
void* operator new[](size_t size);
void operator delete(void* ptr);
void operator delete[](void* ptr);
void operator delete(void* ptr, size_t size);
void operator delete[](void* ptr, size_t size);