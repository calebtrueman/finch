// SPDX-License-Identifier: MIT OR Apache-2.0
// sandbox_shims.h: _FoundationCShims includes it when built into
// Foundation.framework (Apple's is internal). Finch has no app sandbox yet:
// every process is unsandboxed.
#pragma once
#include <sys/types.h>
static inline int _foundation_sandbox_check(pid_t pid, const char * _Nullable operation) {
    return 0;
}
