#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Carbon.framework: Finch's. An umbrella (version.c) re-exporting ApplicationServices and
# HIToolbox, as Apple's does; so far HIToolbox has Carbon events (CarbonEvents.c) and raw
# key translation with dead keys (TSM.c). Apple's other subframeworks come as apps need them.
#   userland/Carbon/build.sh -> build/root/System/Library/Frameworks/Carbon.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Carbon"
CARBON=/System/Library/Frameworks/Carbon.framework/Versions/A
"${FINCH_ROOT}/tools/build-small-framework.sh" \
    "${CARBON}/Frameworks/HIToolbox.framework/Versions/A/HIToolbox" 1249.3 1 com.apple.HIToolbox 2.1.1 \
    "${HERE}/CarbonEvents.c" "${HERE}/TSM.c" -- -Wl,-umbrella,Carbon -framework CoreFoundation
"${FINCH_ROOT}/tools/build-small-framework.sh" "${CARBON}/Carbon" 170 2 com.apple.carbonframework 1.6 \
    "${HERE}/version.c" -- -framework ApplicationServices \
    -Wl,-reexport_library,"${FINCH_ROOT}/build/root${CARBON}/Frameworks/HIToolbox.framework/Versions/A/HIToolbox" \
    -Wl,-reexport_framework,ApplicationServices
ln -sfn Versions/Current/Frameworks "${FINCH_ROOT}/build/root/System/Library/Frameworks/Carbon.framework/Frameworks"
