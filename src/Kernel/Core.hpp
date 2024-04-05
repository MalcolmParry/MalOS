#pragma once

using s8 = char;
using s16 = short;
using s32 = int;
using s64 = long long;

using u8 = unsigned char;
using u16 = unsigned short;
using u32 = unsigned int;
using u64 = unsigned long long;

using f32 = float;
using f64 = double;

#define S8_MIN (-127i8 - 1)
#define S16_MIN (-32767i16 - 1)
#define S32_MIN (-2147483647i32 - 1)
#define S64_MIN (-9223372036854775807i64 - 1)

#define S8_MAX 127i8
#define S16_MAX 32767i16
#define S32_MAX 2147483647i32
#define S64_MAX 9223372036854775807i64

#define U8_MAX 0xffui8
#define U16_MAX 0xffffui16
#define U32_MAX 0xffffffffui32
#define U64_MAX 0xffffffffffffffffui64

static_assert(sizeof(u8) == 1);
static_assert(sizeof(u16) == 2);
static_assert(sizeof(u32) == 4);
static_assert(sizeof(u64) == 8);

static_assert(sizeof(s8) == 1);
static_assert(sizeof(s16) == 2);
static_assert(sizeof(s32) == 4);
static_assert(sizeof(s64) == 8);

static_assert(sizeof(f32) == 4);
static_assert(sizeof(f64) == 8);

namespace kernel {
    extern "C" u8 error;
}

namespace k = kernel;