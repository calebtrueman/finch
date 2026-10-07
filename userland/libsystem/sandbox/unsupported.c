/* SPDX-License-Identifier: MIT OR Apache-2.0
 * No boot-image caller uses these manifest and GPU bundle helpers.
 * Refuse them until Finch supports them; never report protection applied.
 */
#include <errno.h>
#include <stddef.h>
#include <stdbool.h>
#include "internal.h"

static int unsupported(void) { errno = ENOTSUP; return -1; }

EXPORT int rootless_apply_internal(const void *manifest, const char *base, const char *path, unsigned flags)
{ (void)manifest; (void)base; (void)path; (void)flags; return unsupported(); }
EXPORT int rootless_apply(const void *manifest, const char *path)
{ return rootless_apply_internal(manifest, NULL, path, 0); }
EXPORT int rootless_apply_relative(const void *manifest, const char *base, const char *path)
{ return rootless_apply_internal(manifest, base, path, 0); }
EXPORT void *rootless_manifest_parse(const char *path)
{ (void)path; errno = ENOTSUP; return NULL; }
EXPORT void rootless_manifest_free(void *manifest)
{ if (manifest) errno = ENOTSUP; }
EXPORT bool rootless_preflight(const char *path, const void *manifest)
{ (void)path; (void)manifest; errno = ENOTSUP; return false; }
EXPORT int rootless_convert_to_datavault(const char *path, const char *name)
{ (void)path; (void)name; return unsupported(); }
EXPORT int gpu_bundle_is_path_trusted(const char *path)
{ (void)path; return unsupported(); }
EXPORT int gpu_bundle_find_trusted(const char *name, char *path, size_t size)
{ (void)name; if (path && size) path[0] = 0; return unsupported(); }
