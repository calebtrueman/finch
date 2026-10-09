#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# RecapPerformanceTesting.framework (private): the performance-test runner
# apps like TextEdit link, as Finch's own stand-in (RecapPerformanceTesting.m).
#
#   userland/RecapPerformanceTesting/build.sh
#     -> build/root/System/Library/PrivateFrameworks/RecapPerformanceTesting.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/RecapPerformanceTesting"
OBJ="${FINCH_ROOT}/build/obj/RecapPerformanceTesting"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/PrivateFrameworks/RecapPerformanceTesting.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}" "${FW}/Versions/A"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-objc-arc -fblocks \
    -Wall -Wextra -Werror -Wno-unused-parameter -c "${HERE}/RecapPerformanceTesting.m" -o "${OBJ}/RPT.o"
log "linking"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/PrivateFrameworks/RecapPerformanceTesting.framework/Versions/A/RecapPerformanceTesting \
    -current_version 50 -compatibility_version 1 "${OBJ}/RPT.o" -o "${FW}/Versions/A/RecapPerformanceTesting" \
    -F"${ROOT}/System/Library/Frameworks" -framework Foundation -lobjc
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/RecapPerformanceTesting "${FW}/RecapPerformanceTesting"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A RecapPerformanceTesting com.apple.RecapPerformanceTesting RecapPerformanceTesting 1.0 50 English
codesign -f -s - -i com.apple.RecapPerformanceTesting "${FW}/Versions/A/RecapPerformanceTesting" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
