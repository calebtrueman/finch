#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ImageIO.framework: Finch's ImageIO (docs/design/COREGRAPHICS.md), Apple's C
# API (CGImageSource, CGImageDestination, the property keys) over the open
# codecs Skia builds: libpng, libjpeg-turbo, libwebp, wuffs (GIF) and Skia's
# BMP and ICO readers, linked statically. Compiled against the SDK's ImageIO
# headers so every function has Apple's signature; CGImages are made with
# Finch's CoreGraphics.
#
# Linked as Apple ships it: Versions/A, current and compatibility version 1
# (the SDK's ImageIO.tbd), exporting only ImageIO's symbols.
#
#   userland/ImageIO/build.sh
#     -> build/root/System/Library/Frameworks/ImageIO.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/ImageIO"
OBJ="${FINCH_ROOT}/build/obj/ImageIO"
SKIA_OBJ="${FINCH_ROOT}/build/obj/skia"
SKIA_SRC="${FINCH_ROOT}/build/src/skia"
EXT="${SKIA_SRC}/third_party/externals"
ROOT="${FINCH_ROOT}/build/root"
FWS="${ROOT}/System/Library/Frameworks"
FW="${FWS}/ImageIO.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
CXX="$(xcrun -f clang++)"
log() { echo "==> $*"; }

[[ -f "${FWS}/CoreGraphics.framework/Versions/A/CoreGraphics" ]] || { echo "build CoreGraphics first: userland/CoreGraphics/build.sh" >&2; exit 1; }
[[ -f "${SKIA_OBJ}/libskia.a" ]] || "${FINCH_ROOT}/userland/skia/build.sh"

COMMON=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-common -fblocks
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations)
CFLAGS=("${COMMON[@]}" -std=c17)
CXXFLAGS=("${COMMON[@]}" -std=c++20 -fno-exceptions -fno-rtti -Wno-missing-field-initializers -Wno-deprecated-anon-enum-enum-conversion
    -I"${SKIA_SRC}" -I"${SKIA_SRC}/third_party/libpng" -I"${EXT}/libpng" -I"${EXT}/libjpeg-turbo/src"
    -I"${EXT}/zlib" -I"${EXT}/libwebp/src"
    $(cd "${SKIA_SRC}" && bin/gn desc "${SKIA_OBJ}" //:skia defines | grep -v SKIA_IMPLEMENTATION | sed 's/^/-D/'))

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/*.c; do
    "${CC}" "${CFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.c}").o"
done
for f in "${HERE}"/*.cpp; do
    "${CXX}" "${CXXFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.cpp}").o"
done

log "linking"
mkdir -p "${FW}/Versions/A"
"${CXX}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/ImageIO.framework/Versions/A/ImageIO \
    -current_version 1 -compatibility_version 1 \
    "${OBJ}"/*.o -o "${FW}/Versions/A/ImageIO" \
    -Wl,-exported_symbols_list,"${HERE}/exports.txt" -Wl,-dead_strip \
    "${SKIA_OBJ}/libskia.a" "${SKIA_OBJ}/libskcms.a" \
    "${SKIA_OBJ}/libpng.a" "${SKIA_OBJ}/libjpeg.a" "${SKIA_OBJ}/libwebp.a" \
    "${SKIA_OBJ}/libwebp_sse41.a" "${SKIA_OBJ}/libwuffs.a" "${SKIA_OBJ}/libzlib.a" \
    -F"${FWS}" -framework CoreGraphics -framework CoreFoundation -lc++ -lSystem
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/ImageIO "${FW}/ImageIO"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A ImageIO com.apple.ImageIO ImageIO 3.3.0 2784.4.14 English
codesign -f -s - -i com.apple.ImageIO "${FW}/Versions/A/ImageIO" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
