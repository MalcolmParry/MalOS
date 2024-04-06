#include "Heap.hpp"

namespace kernel::Heap {
	enum PageFlag : u8 {
		PageFlagFree,
		PageFlagUsed,
		PageFlagStart,
		PageFlagEnd
	};

	constexpr u32 pageSize = 8;
	constexpr u32 pageCount = 1024;

	struct Page {
		u8 data[pageSize];
	};

	PageFlag header[pageCount];
	Page heap[pageCount];

	void Init() {
		for (u32 i = 0; i < pageCount; i++) {
			header[i] = PageFlagFree;
		}
	}

	void* Alloc(size_t size) {
		u32 toAllocate = size / pageSize;
		if (size % pageSize != 0) {
			toAllocate++;
		}

		u32 freeStart = U32_MAX;
		u32 freeSize = 0;
		for (u32 i = 0; i < pageCount; i++) {
			if (header[i] == PageFlagFree) {
				freeSize++;

				if (freeStart == U32_MAX)
					freeStart = i;
				
				if (freeSize == toAllocate) {
					break;
				}
			} else {
				freeStart = U32_MAX;
				freeSize = 0;
			}
		}

		if (freeStart == U32_MAX || freeSize != toAllocate) {
			return nullptr;
		}

		if (freeSize == 1) {
			header[freeStart] = PageFlagEnd;
			return (void*) &heap[freeStart];
		}

		header[freeStart] = PageFlagStart;
		header[freeStart + freeSize - 1] = PageFlagEnd; 

		for (u32 i = 0; i < freeSize - 2; i++) {
			header[freeStart + i + 1] = PageFlagUsed;
		}

		return (void*) &heap[freeStart];
	}

	void Free(void* ptr) {
		u64 heapOffset = ((u64) ptr) - ((u64) &heap);
		u64 i = heapOffset / pageSize;

		while (header[i] != PageFlagFree) {
			if (header[i] == PageFlagEnd) {
				header[i] = PageFlagFree;
				return;
			}

			header[i] = PageFlagFree;
			i++;
		}
	}

	void Free(void* ptr, size_t size) {
		u64 heapOffset = ((u64) ptr) - ((u64) &heap);
		u64 start = heapOffset / pageSize;
		
		for (size_t i = 0; i < size / pageSize; i++) {
			header[i + start] = PageFlagFree;
		}
	}
}

void* operator new(size_t size) {
	return k::Heap::Alloc(size);
}

void* operator new[](size_t size) {
	return k::Heap::Alloc(size);
}

void operator delete(void* ptr) {
	k::Heap::Free(ptr);
}

void operator delete[](void* ptr) {
	k::Heap::Free(ptr);
}

void operator delete(void* ptr, size_t size) {
	k::Heap::Free(ptr, size);
}

void operator delete[](void* ptr, size_t size) {
	k::Heap::Free(ptr, size);
}