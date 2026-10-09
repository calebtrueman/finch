#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ICADevices.framework: the Image Capture device-module library, as its public
# API (the SDK's headers) with nothing behind it until Finch has device modules
# (ICADevices.c's header comment).
#
# Linked as Apple ships it: Versions/A, current version 1, compatibility version 1.
#
#   userland/ICADevices/build.sh -> build/root/System/Library/Frameworks/ICADevices.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/ICADevices"
OBJ="${FINCH_ROOT}/build/obj/ICADevices"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/ICADevices.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-common
    -Wall -Wextra -Werror -Wno-unused-parameter)

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
"${CC}" "${CFLAGS[@]}" -c "${HERE}/ICADevices.c" -o "${OBJ}/ICADevices.o"

log "linking"
mkdir -p "${FW}/Versions/A"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/ICADevices.framework/Versions/A/ICADevices \
    -current_version 1 -compatibility_version 1 "${OBJ}/ICADevices.o" -o "${FW}/Versions/A/ICADevices" \
    -F"${ROOT}/System/Library/Frameworks" -framework CoreFoundation -framework CoreGraphics
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/ICADevices "${FW}/ICADevices"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A ICADevices com.apple.ICADevices ICADevices 2020.2.2 2020.2.2 en
codesign -f -s - -i com.apple.ICADevices "${FW}/Versions/A/ICADevices" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
