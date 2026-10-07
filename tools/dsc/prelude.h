/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Force-included into the cache builder build (tools/dsc/build-builder.sh):
 * macros Apple's internal headers define that the published dyld headers use.
 */

/* ExclaveKit availability: no restriction when building for macOS. */
#ifndef DYLD_EXCLAVEKIT_UNAVAILABLE
#define DYLD_EXCLAVEKIT_UNAVAILABLE
#endif

/* Mac Catalyst's platform number under its old name. */
#ifndef PLATFORM_IOSMAC
#define PLATFORM_IOSMAC PLATFORM_MACCATALYST
#endif

/* Architectures the builder supports. Apple's internal headers define these;
 * without them the builder can't name arm64e at all. */
#ifndef SUPPORT_ARCH_arm64e
#define SUPPORT_ARCH_arm64e 1
#endif
#ifndef SUPPORT_ARCH_arm64_32
#define SUPPORT_ARCH_arm64_32 1
#endif
