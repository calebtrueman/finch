// SPDX-License-Identifier: MIT OR Apache-2.0
// What the Darwin overlays use of dyld's private mach-o/dyld_priv.h.
#pragma once
#include <mach-o/loader.h>
extern const struct mach_header * _Nullable _dyld_get_dlopen_image_header(void * _Nonnull handle);
