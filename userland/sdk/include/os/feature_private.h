/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <os/feature_private.h>: feature-flag queries, backed by
 * libsystem_featureflags. Apple doesn't publish this header or that library.
 * The ABI here matches what macOS 26.4's libraries call:
 *
 *   bool _os_feature_enabled_simple_impl(const char *domain,
 *                                        const char *feature, bool fallback);
 *   bool _os_feature_enabled_impl(const char *domain, const char *feature);
 *
 * Callers name domains and features as bare identifiers, e.g.
 * os_feature_enabled_simple(libmalloc, ZeroOnFree, true), which the macros
 * stringify.
 */

#ifndef __OS_FEATURE_PRIVATE_H__
#define __OS_FEATURE_PRIVATE_H__

#include <stdbool.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

bool _os_feature_enabled_impl(const char *domain, const char *feature);
bool _os_feature_enabled_simple_impl(const char *domain, const char *feature,
    bool fallback);

__END_DECLS

#define os_feature_enabled(domain, feature) \
	_os_feature_enabled_impl(#domain, #feature)
#define os_feature_enabled_simple(domain, feature, fallback) \
	_os_feature_enabled_simple_impl(#domain, #feature, fallback)

#endif /* __OS_FEATURE_PRIVATE_H__ */
