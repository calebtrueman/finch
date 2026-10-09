// SPDX-License-Identifier: MIT OR Apache-2.0
// What swift-foundation (FOUNDATION_FRAMEWORK) uses of libxpc's private
// header. Finch has no app sandbox yet.
#pragma once
#include <stdbool.h>
static inline bool _xpc_runtime_is_app_sandboxed(void) {
    return false;
}
