/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_platform's own crash annotations (__DATA,__crash_info), as in
 * Apple's library. os/crashlog_private.h writes the abort message and cause
 * straight into gCRAnnotations; libplatform sits below libpthread, so it
 * can't use libCrashReporterClient.a's setters.
 */

#include <CrashReporterClient.h>

struct crashreporter_annotations_t gCRAnnotations
    __attribute__((section("__DATA," CRASHREPORTER_ANNOTATIONS_SECTION), used)) = {
	.version = CRASHREPORTER_ANNOTATIONS_VERSION,
};
