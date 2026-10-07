// Copyright (c) 2026 The Finch Project contributors.
// SPDX-License-Identifier: MIT OR Apache-2.0
//
// libc++'s hardening hook: Apple's libc++ reports a failed hardening check
// here before trapping. Finch writes the message to stderr (Finch's os_log
// isn't in place yet); the caller still traps.

#include <string.h>
#include <unistd.h>

namespace std {
inline namespace __1 {
__attribute__((visibility("default"))) void
__internal_log_hardening_failure(const char *message) noexcept
{
	static const char prefix[] = "libc++ hardening check failed: ";
	(void)write(STDERR_FILENO, prefix, sizeof(prefix) - 1);
	if (message != nullptr) (void)write(STDERR_FILENO, message, strlen(message));
	(void)write(STDERR_FILENO, "\n", 1);
}
} // namespace __1
} // namespace std
