#pragma once

#include <stddef.h>

using u8 = unsigned char;
using u16 = unsigned short;
using u32 = unsigned int;
using u64 = unsigned long long;

using s8 = char;
using s16 = short;
using s32 = int;
using s64 = long long;

using f32 = float;
using f64 = double;

#define U8_MAX ((u8) 0xff)
#define U16_MAX ((u16) 0xffff)
#define U32_MAX ((u32) 0xffff'ffff)
#define U64_MAX ((u64) 0xffff'ffff'ffff'ffff)

#define S8_MAX ((s8) (U8_MAX / 2))
#define S16_MAX ((s16) (U16_MAX / 2))
#define S32_MAX ((s32) (U32_MAX / 2))
#define S64_MAX ((s64) (U64_MAX / 2))

#define S8_MIN (-S8_MAX - 1)
#define S16_MIN (-S16_MAX - 1)
#define S32_MIN (-S32_MAX - 1)
#define S64_MIN (-S64_MAX - 1)

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

using type_t = u64;

namespace kernel {
	// compile time type ids
	template<class T>
	struct TypeIdentifier {
		constexpr static type_t id() {
			return (type_t) (&_id);
		}
	private:
		constexpr static u8 _id {};
	};

	extern "C" u8 error;
}

namespace k = kernel;

#define ctypeid(T) (k::TypeIdentifier<T>::id())
#define hlt __asm("hlt")