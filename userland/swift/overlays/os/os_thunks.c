// SPDX-License-Identifier: MIT OR Apache-2.0
// Replaces the historical overlay's thunks.mm: reports a fatal formatting
// error through the Swift runtime, without C++.
#include <stdint.h>
extern void swift_reportError(uint32_t flags, const char *message);
__attribute__((visibility("hidden"))) void
_swift_os_log_reportError(uint32_t flags, const char *message)
{
    swift_reportError(flags, message);
}
