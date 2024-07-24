#include "Utils.hpp"

namespace kernel {
    void u64tostr(char* buf, u64 n, u8 base) {
        for (u8 i = 0; n != 0; i++) {
            u32 rem = n % base;
            buf[i] = (rem < 10) ? (rem + '0') : (rem + 'a' - 10);
            n = n / base;
        }

        strreverse(buf);
    }

    void memset(void* dst, u8 src, u64 n) {
        for (u64 i = 0; i < n; i++) {
            ((u8*) dst)[i] = src;
        }
    }

    void memcpy(void* dst, const void* src, u64 n) {
        for (u64 i = 0; i < n; i++) {
            ((u8*) dst)[i] = ((u8*) src)[i];
        }
    }

    void memmove(void* dst, const void* src, u64 n) {
        memcpy(dst, src, n);
    }

    u32 strlen(const char* str) {
        u32 len = 0;
        for (; str[len] != '\0'; len++) {}
        return len;
    }

    void strcat(char* dst, const char* src) {
        memcpy(dst + strlen(dst), src, strlen(src));
    }

    void strcpy(char* dst, const char* src) {
        memcpy(dst, src, strlen(src));
    }

    bool strcmp(const char* a, const char* b) {
        u32 i = 0;

        while (true) {
            if (a[i] != b[i])
                return false;

            if (a[i] == '\0')
                return true;

            i++;
        }
    }

    void strreverse(char* str) {
        u32 len = strlen(str);

        char* start = str;
        char* end = str + len - 1;

        while (start < end) {
            char tmp = *start;
            *start = *end;
            *end = tmp;
            start++;
            end--;
        }
    }
}
