#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreUI.framework (private): Finch's reader for compiled asset catalogs
# (Assets.car), with the part of Apple's CoreUI API that AppKit and apps use
# to look up named colours, images and data (CUICatalog.h). The format, as
# Finch worked it out from real catalogs, is in docs/design/ASSETS.md.
#
# Linked as Apple's: Versions/A, current version 974.1, compatibility version 1.
# libcompression (LZFSE, LZVN) and zlib come from the SDK's stubs; at run time
# Finch's are loaded (same install names).
#
#   userland/CoreUI/build.sh -> build/root/System/Library/PrivateFrameworks/CoreUI.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreUI"
OBJ="${FINCH_ROOT}/build/obj/CoreUI"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/PrivateFrameworks/CoreUI.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

for dep in Foundation CoreGraphics ImageIO; do
    [[ -f "${ROOT}/System/Library/Frameworks/${dep}.framework/${dep}" ]] || { echo "build ${dep} first" >&2; exit 1; }
done

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-objc-arc -fobjc-exceptions -fblocks
    -fno-common -Wall -Wextra -Werror -Wno-unused-command-line-argument -Wno-unused-parameter -Wno-objc-property-implementation -Wno-nullability
    -Wno-incomplete-implementation -Wno-sign-compare -I"${HERE}")

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/*.c "${HERE}"/*.m; do
    "${CC}" "${CFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.*}").o"
done

log "linking"
mkdir -p "${FW}/Versions/A"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/PrivateFrameworks/CoreUI.framework/Versions/A/CoreUI \
    -current_version 974.1 -compatibility_version 1 "${OBJ}"/*.o -o "${FW}/Versions/A/CoreUI" \
    -F"${ROOT}/System/Library/Frameworks" -framework Foundation -framework CoreFoundation -framework CoreGraphics \
    -framework ImageIO -lcompression -lz -lobjc
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/CoreUI "${FW}/CoreUI"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A CoreUI com.apple.coreui CoreUI 2.1 974.1 English
codesign -f -s - -i com.apple.coreui "${FW}/Versions/A/CoreUI" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
