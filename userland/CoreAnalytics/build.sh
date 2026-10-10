#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreAnalytics.framework (private): Finch's, collecting nothing (CoreAnalytics.c).
#   userland/CoreAnalytics/build.sh -> build/root/System/Library/PrivateFrameworks/CoreAnalytics.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/PrivateFrameworks/CoreAnalytics.framework/Versions/A/CoreAnalytics 1 1 com.apple.CoreAnalytics 1.0 \
    "${FINCH_ROOT}/userland/CoreAnalytics/CoreAnalytics.c" -- -framework CoreFoundation
