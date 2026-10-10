#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# HIServices.framework, inside ApplicationServices as Apple's is: Finch's. So far the
# accessibility client API and Universal Access settings (Accessibility.c), the Process
# Manager (Processes.c) and Apple's constants (HIServicesConstants.c).
#   userland/HIServices/build.sh
#     -> build/root/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/HIServices"
AS=/System/Library/Frameworks/ApplicationServices.framework
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    "${AS}/Versions/A/Frameworks/HIServices.framework/Versions/A/HIServices" 817 1 com.apple.HIServices 1.22 \
    "${HERE}/HIServicesConstants.c" "${HERE}/Accessibility.c" "${HERE}/Processes.c" \
    -- -Wl,-umbrella,ApplicationServices -framework CoreFoundation
ln -sfn Versions/Current/Frameworks "${FINCH_ROOT}/build/root${AS}/Frameworks"
