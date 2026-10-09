#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreVideo.framework: Finch's CoreVideo. So far the display link and the host clock
# (CVDisplayLink.c); pixel buffers and their pools come with the media frameworks.
# Compiled against the SDK's headers so every function has Apple's signature.
#
# Linked as Apple ships it: Versions/A, current version 734.4, compatibility version 1.2.
#
#   userland/CoreVideo/build.sh -> build/root/System/Library/Frameworks/CoreVideo.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreVideo"
OBJ="${FINCH_ROOT}/build/obj/CoreVideo"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/CoreVideo.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

[[ -f "${ROOT}/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics" ]] || { echo "build CoreGraphics first" >&2; exit 1; }

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fblocks \
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations \
    -c "${HERE}/CVDisplayLink.c" -o "${OBJ}/CVDisplayLink.o"

log "linking"
mkdir -p "${FW}/Versions/A"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/CoreVideo.framework/Versions/A/CoreVideo \
    -current_version 734.4 -compatibility_version 1.2 \
    "${OBJ}"/*.o -o "${FW}/Versions/A/CoreVideo" \
    -F"${ROOT}/System/Library/Frameworks" -framework CoreFoundation -framework CoreGraphics
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/CoreVideo "${FW}/CoreVideo"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A CoreVideo com.apple.CoreVideo CoreVideo 1.8 734.4 English
codesign -f -s - -i com.apple.CoreVideo "${FW}/Versions/A/CoreVideo" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
