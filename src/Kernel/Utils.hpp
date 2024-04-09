#include "Core.hpp"

namespace kernel {
	constexpr u8 u64tostrBufSize = 21;
	void u64tostr(char *buf, u64 n, u8 base);

	void memset(void* dst, u8 src, u64 n);
	void memcpy(void* dst, const void* src, u64 n);

	u32 strlen(const char* str);
	void strcat(char* dst, const char* src);
	void strcpy(char* dst, const char* src);
	bool strcmp(const char* a, const char* b);
	void strreverse(char* str);
}