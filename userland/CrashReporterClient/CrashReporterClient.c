/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libCrashReporterClient.a: see CrashReporterClient.h. Linked statically, so
 * every image that uses it carries its own record (as on macOS).
 */

#include <pthread.h>

#include "CrashReporterClient.h"

struct crashreporter_annotations_t gCRAnnotations
    __attribute__((section("__DATA," CRASHREPORTER_ANNOTATIONS_SECTION), used)) = {
	.version = CRASHREPORTER_ANNOTATIONS_VERSION,
};

static uint64_t
current_thread(void)
{
	uint64_t tid = 0;
	pthread_threadid_np(NULL, &tid);
	return tid;
}

const char *
CRGetCrashLogMessage(void)
{
	return (const char *)(uintptr_t)gCRAnnotations.message;
}

void
CRSetCrashLogMessage(const char *message)
{
	gCRAnnotations.message = (uint64_t)(uintptr_t)message;
	gCRAnnotations.thread = message ? current_thread() : 0;
}

const char *
CRGetCrashLogMessage2(void)
{
	return (const char *)(uintptr_t)gCRAnnotations.message2;
}

void
CRSetCrashLogMessage2(const char *message)
{
	gCRAnnotations.message2 = (uint64_t)(uintptr_t)message;
}

void
CRSetBacktrace(const char *backtrace)
{
	gCRAnnotations.backtrace = (uint64_t)(uintptr_t)backtrace;
}

void
CRSetSignatureString(const char *signature)
{
	gCRAnnotations.signature_string = (uint64_t)(uintptr_t)signature;
}

void
CRSetDialogMode(unsigned int mode)
{
	gCRAnnotations.dialog_mode = mode;
}

void
CRSetAbortCause(uint64_t cause)
{
	gCRAnnotations.abort_cause = cause;
}
