/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <CrashReporterClient.h>: crash annotations. Code that links
 * libCrashReporterClient.a gets a per-image record in __DATA,__crash_info
 * that crash reporters read from a dying process: a message, a second
 * message, a signature and a backtrace string. The record layout is version 5
 * of crashreporter_annotations_t, the layout crash reporters such as Crashpad
 * read. macOS 26 itself writes version 7, which extends version 5.
 */

#ifndef _CRASHREPORTERCLIENT_H_
#define _CRASHREPORTERCLIENT_H_

#include <stdint.h>
#include <sys/cdefs.h>

#define CRASHREPORTER_ANNOTATIONS_SECTION "__crash_info"
#define CRASHREPORTER_ANNOTATIONS_VERSION 5
#define CRASH_REPORTER_CLIENT_HIDDEN __attribute__((visibility("hidden")))

struct crashreporter_annotations_t {
	uint64_t version;            /* CRASHREPORTER_ANNOTATIONS_VERSION */
	uint64_t message;            /* const char * */
	uint64_t signature_string;   /* const char * */
	uint64_t backtrace;          /* const char * */
	uint64_t message2;           /* const char * */
	uint64_t thread;             /* thread the message concerns */
	unsigned int dialog_mode;
	uint64_t abort_cause;        /* version >= 5 */
};

__BEGIN_DECLS

CRASH_REPORTER_CLIENT_HIDDEN extern struct crashreporter_annotations_t gCRAnnotations;

CRASH_REPORTER_CLIENT_HIDDEN const char *CRGetCrashLogMessage(void);
CRASH_REPORTER_CLIENT_HIDDEN void CRSetCrashLogMessage(const char *message);
CRASH_REPORTER_CLIENT_HIDDEN const char *CRGetCrashLogMessage2(void);
CRASH_REPORTER_CLIENT_HIDDEN void CRSetCrashLogMessage2(const char *message);
CRASH_REPORTER_CLIENT_HIDDEN void CRSetBacktrace(const char *backtrace);
CRASH_REPORTER_CLIENT_HIDDEN void CRSetSignatureString(const char *signature);
CRASH_REPORTER_CLIENT_HIDDEN void CRSetDialogMode(unsigned int mode);
CRASH_REPORTER_CLIENT_HIDDEN void CRSetAbortCause(uint64_t cause);

__END_DECLS

#endif
