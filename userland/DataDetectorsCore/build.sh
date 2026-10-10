#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# DataDetectorsCore.framework (private): Finch's. The scanner (DDScanner.c) finds links,
# email addresses, phone numbers and IP addresses in text, as Apple's does.
#   userland/DataDetectorsCore/build.sh
#     -> build/root/System/Library/PrivateFrameworks/DataDetectorsCore.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/DataDetectorsCore"
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/PrivateFrameworks/DataDetectorsCore.framework/Versions/A/DataDetectorsCore 821.6 1 \
    com.apple.DataDetectorsCore 5.0 "${HERE}/DDScanner.c" -- -framework CoreFoundation
