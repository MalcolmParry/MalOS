#include "Heap.hpp"

namespace kernel::Heap {
    constexpr u32 pageSize = 8;
    constexpr u32 pageCount = 1024;

    enum PageFlag : u8 {
        PageFlagFree,
        PageFlagUsed,
        PageFlagStart,
        PageFlagEnd
    };

    struct Page {
        u8 data[pageSize];
    } __attribute__((packed));

    PageFlag header[pageCount];
    Page heap[pageCount];

    void Init() {
        for (u32 i = 0; i < pageCount; i++) {
            header[i] = PageFlagFree;
        }
    }

    void* Alloc(u64 size) {
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

    void* Realloc(void* ptr, u64 size) {
        u64 heapOffset = ((u64) ptr) - ((u64) &heap);
        u64 start = heapOffset / pageSize;
        u64 origSize = 0;

        for (; header[origSize + start] != PageFlagFree; origSize++) {}

        if (origSize > size) {
            header[start + size - 1] = PageFlagEnd;
            for (u64 i = size; i < origSize; i++) {
                header[start + i] = PageFlagFree;
            }
        }

        u64 extraSize = 0;
        for (; header[start + origSize + extraSize] == PageFlagFree; extraSize++) {}

        if (origSize + extraSize < size) {
            void* ret = Alloc(size);
            memcpy(ret, ptr, origSize);
            Free(ptr);
            return ret;
        }

        header[start] = PageFlagStart;
        header[start + size - 1] = PageFlagEnd;
        for (u64 i = origSize - 1; i < size - 1; i++) {
            header[start + i] = PageFlagUsed;
        }

        return ptr;
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

void* operator new(size_t size) { return k::Heap::Alloc(size); }

void* operator new[](size_t size) { return k::Heap::Alloc(size); }

void operator delete(void* ptr) { k::Heap::Free(ptr); }

void operator delete[](void* ptr) { k::Heap::Free(ptr); }

void operator delete(void* ptr, size_t size) { k::Heap::Free(ptr, size); }

void operator delete[](void* ptr, size_t size) { k::Heap::Free(ptr, size); }
