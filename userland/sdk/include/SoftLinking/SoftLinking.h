/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <SoftLinking/SoftLinking.h>: Apple-internal macros (not published) for
 * calling into a library or framework loaded on first use with dlopen. Finch's
 * version: when the library or symbol isn't present, the call does nothing and
 * returns zero, instead of crashing. (su soft-links libEndpointSecuritySystem,
 * which Finch doesn't have.)
 *
 *   SOFT_LINK_DYLIB(libFoo)                      /usr/lib/libFoo.dylib
 *   SOFT_LINK_FRAMEWORK(Frameworks, Foo)         /System/Library/Frameworks/Foo.framework/Foo
 *   SOFT_LINK_FUNCTION(lib, name, local, ret, (params), (args))
 *       defines `ret local(params)`, calling `name` in lib, and
 *       `bool is<lib><name>Available(void)`.
 */
#ifndef _FINCH_SOFTLINKING_H_
#define _FINCH_SOFTLINKING_H_

#include <dlfcn.h>
#include <stdbool.h>

/* Stands in for a missing function: returns zero. */
static inline long
_finch_soft_link_missing(void)
{
	return 0;
}

#define SOFT_LINK_DYLIB(lib)                                               \
	static void *lib##Library(void)                                    \
	{                                                                  \
		static void *handle;                                       \
		static bool tried;                                         \
		if (!tried) {                                              \
			handle = dlopen("/usr/lib/" #lib ".dylib", RTLD_LAZY | RTLD_LOCAL); \
			tried = true;                                      \
		}                                                          \
		return handle;                                             \
	}

#define SOFT_LINK_FRAMEWORK(directory, framework)                          \
	static void *framework##Library(void)                              \
	{                                                                  \
		static void *handle;                                       \
		static bool tried;                                         \
		if (!tried) {                                              \
			handle = dlopen("/System/Library/" #directory "/" #framework \
			    ".framework/" #framework, RTLD_LAZY | RTLD_LOCAL); \
			tried = true;                                      \
		}                                                          \
		return handle;                                             \
	}

#define SOFT_LINK_FUNCTION(lib, name, local, ret, params, args)            \
	__attribute__((unused)) static bool is##lib##name##Available(void) \
	{                                                                  \
		void *h = lib##Library();                                  \
		return h != NULL && dlsym(h, #name) != NULL;               \
	}                                                                  \
	__attribute__((unused)) static ret local params                    \
	{                                                                  \
		static ret (*function) params;                             \
		static bool tried;                                         \
		if (!tried) {                                              \
			void *h = lib##Library();                          \
			function = h ? (ret (*) params)dlsym(h, #name) : NULL; \
			if (function == NULL)                              \
				function = (ret (*) params)(void *)_finch_soft_link_missing; \
			tried = true;                                      \
		}                                                          \
		return function args;                                      \
	}

#define SOFT_LINK_FUNCTION_FOR_HEADER(lib, name, local, ret, params, args) \
	SOFT_LINK_FUNCTION(lib, name, local, ret, params, args)

#define SOFT_LINK_MAY_FAIL(lib, name, local, ret, params, args)            \
	SOFT_LINK_FUNCTION(lib, name, local, ret, params, args)               \
	static bool canLoad_##local(void)                                  \
	{                                                                  \
		void *h = lib##Library();                                  \
		return h != NULL && dlsym(h, #name) != NULL;               \
	}

#endif /* !_FINCH_SOFTLINKING_H_ */
