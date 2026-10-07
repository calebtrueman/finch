// Copyright (c) 2026 The Finch Project contributors.
// SPDX-License-Identifier: MIT OR Apache-2.0
//
// Typed operator new/delete for libc++abi: Apple's libc++abi exports
// variants taking a std::__type_descriptor_t (passed as a 64-bit integer),
// which the compiler emits so malloc can segregate allocations by type.
// Upstream LLVM 21 doesn't have them. Allocation forwards the descriptor to
// malloc_type_* and follows operator new's usual new-handler / bad_alloc
// rules; deallocation is the untyped delete, as in Apple's library. Exported
// weak, as Apple's are.

#include <cstddef>
#include <cstdlib>
#include <malloc/_malloc_type.h>
#include <new>

namespace std {
enum class __type_descriptor_t : unsigned long long {};
}

#define WEAK __attribute__((weak, visibility("default")))

static void *
typed_alloc(std::size_t size, std::__type_descriptor_t td)
{
	if (size == 0) size = 1;
	void *p;
	while ((p = malloc_type_malloc(size, static_cast<malloc_type_id_t>(td))) == nullptr) {
		std::new_handler handler = std::get_new_handler();
		if (handler == nullptr) throw std::bad_alloc();
		handler();
	}
	return p;
}

static void *
typed_aligned_alloc(std::size_t size, std::__type_descriptor_t td, std::align_val_t alignment)
{
	std::size_t align = static_cast<std::size_t>(alignment);
	if (size == 0) size = 1;
	if (align < sizeof(void *)) align = sizeof(void *);
	size = (size + align - 1) & ~(align - 1);   // aligned_alloc wants a multiple
	void *p;
	while ((p = malloc_type_aligned_alloc(align, size, static_cast<malloc_type_id_t>(td))) == nullptr) {
		std::new_handler handler = std::get_new_handler();
		if (handler == nullptr) throw std::bad_alloc();
		handler();
	}
	return p;
}

WEAK void *operator new(std::size_t size, std::__type_descriptor_t td) { return typed_alloc(size, td); }
WEAK void *operator new[](std::size_t size, std::__type_descriptor_t td) { return typed_alloc(size, td); }
WEAK void *operator new(std::size_t size, std::__type_descriptor_t td, std::align_val_t a) { return typed_aligned_alloc(size, td, a); }
WEAK void *operator new[](std::size_t size, std::__type_descriptor_t td, std::align_val_t a) { return typed_aligned_alloc(size, td, a); }

WEAK void *
operator new(std::size_t size, std::__type_descriptor_t td, const std::nothrow_t &) noexcept
{
	try { return typed_alloc(size, td); } catch (...) { return nullptr; }
}

WEAK void *
operator new[](std::size_t size, std::__type_descriptor_t td, const std::nothrow_t &) noexcept
{
	try { return typed_alloc(size, td); } catch (...) { return nullptr; }
}

WEAK void *
operator new(std::size_t size, std::__type_descriptor_t td, std::align_val_t a, const std::nothrow_t &) noexcept
{
	try { return typed_aligned_alloc(size, td, a); } catch (...) { return nullptr; }
}

WEAK void *
operator new[](std::size_t size, std::__type_descriptor_t td, std::align_val_t a, const std::nothrow_t &) noexcept
{
	try { return typed_aligned_alloc(size, td, a); } catch (...) { return nullptr; }
}

WEAK void operator delete(void *p, std::__type_descriptor_t) noexcept { ::operator delete(p); }
WEAK void operator delete[](void *p, std::__type_descriptor_t) noexcept { ::operator delete[](p); }
WEAK void operator delete(void *p, std::__type_descriptor_t, std::size_t n) noexcept { ::operator delete(p, n); }
WEAK void operator delete[](void *p, std::__type_descriptor_t, std::size_t n) noexcept { ::operator delete[](p, n); }
WEAK void operator delete(void *p, std::__type_descriptor_t, std::align_val_t a) noexcept { ::operator delete(p, a); }
WEAK void operator delete[](void *p, std::__type_descriptor_t, std::align_val_t a) noexcept { ::operator delete[](p, a); }
WEAK void operator delete(void *p, std::__type_descriptor_t, std::size_t n, std::align_val_t a) noexcept { ::operator delete(p, n, a); }
WEAK void operator delete[](void *p, std::__type_descriptor_t, std::size_t n, std::align_val_t a) noexcept { ::operator delete[](p, n, a); }
WEAK void operator delete(void *p, std::__type_descriptor_t, const std::nothrow_t &t) noexcept { ::operator delete(p, t); }
WEAK void operator delete[](void *p, std::__type_descriptor_t, const std::nothrow_t &t) noexcept { ::operator delete[](p, t); }
WEAK void operator delete(void *p, std::__type_descriptor_t, std::align_val_t a, const std::nothrow_t &t) noexcept { ::operator delete(p, a, t); }
WEAK void operator delete[](void *p, std::__type_descriptor_t, std::align_val_t a, const std::nothrow_t &t) noexcept { ::operator delete[](p, a, t); }
