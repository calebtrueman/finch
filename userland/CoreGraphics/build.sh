#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreGraphics.framework: Finch's CoreGraphics (docs/design/COREGRAPHICS.md),
# Apple's C API over Skia, compiled against the SDK's CoreGraphics headers so
# every function has Apple's signature. Skia and its libraries
# (userland/skia/build.sh) are linked statically.
#
# Linked as Apple ships it: Versions/A, current version 1965.4.5,
# compatibility version 64, exporting only CG symbols.
#
#   userland/CoreGraphics/build.sh
#     -> build/root/System/Library/Frameworks/CoreGraphics.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreGraphics"
OBJ="${FINCH_ROOT}/build/obj/CoreGraphics"
SKIA_OBJ="${FINCH_ROOT}/build/obj/skia"
SKIA_SRC="${FINCH_ROOT}/build/src/skia"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/CoreGraphics.framework"
CFFW="${ROOT}/System/Library/Frameworks/CoreFoundation.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
CXX="$(xcrun -f clang++)"
log() { echo "==> $*"; }

[[ -f "${CFFW}/Versions/A/CoreFoundation" ]] || { echo "build CoreFoundation first: userland/CoreFoundation/build.sh" >&2; exit 1; }
[[ -f "${SKIA_OBJ}/libskia.a" ]] || "${FINCH_ROOT}/userland/skia/build.sh"

COMMON=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-common -fblocks
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations)
CFLAGS=("${COMMON[@]}" -std=c17)
CXXFLAGS=("${COMMON[@]}" -std=c++20 -fno-exceptions -fno-rtti -Wno-missing-field-initializers -I"${SKIA_SRC}"
    -DSK_RELEASE -DSK_CPU_ONLY -DSK_GANESH=0)

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/*.c; do
    "${CC}" "${CFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.c}").o"
done
for f in "${HERE}"/*.cpp; do
    [[ -e "$f" ]] || continue
    "${CXX}" "${CXXFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.cpp}").o"
done

log "linking"
mkdir -p "${FW}/Versions/A"
"${CXX}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics \
    -current_version 1965.4.5 -compatibility_version 64 \
    "${OBJ}"/*.o -o "${FW}/Versions/A/CoreGraphics" \
    -Wl,-exported_symbols_list,"${HERE}/exports.txt" -Wl,-dead_strip \
    "${SKIA_OBJ}/libskia.a" "${SKIA_OBJ}/libskcms.a" "${SKIA_OBJ}/libfreetype2.a" \
    "${SKIA_OBJ}/libpng.a" "${SKIA_OBJ}/libjpeg.a" "${SKIA_OBJ}/libwebp.a" \
    "${SKIA_OBJ}/libwebp_sse41.a" "${SKIA_OBJ}/libwuffs.a" "${SKIA_OBJ}/libzlib.a" \
    -F"${ROOT}/System/Library/Frameworks" -framework CoreFoundation -lc++ -lSystem
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/CoreGraphics "${FW}/CoreGraphics"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A CoreGraphics com.apple.CoreGraphics CoreGraphics 2.0 1965.4.5 English
codesign -f -s - -i com.apple.CoreGraphics "${FW}/Versions/A/CoreGraphics" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
