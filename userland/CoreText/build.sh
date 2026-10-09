#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreText.framework: Finch's CoreText (docs/design/COREGRAPHICS.md), Apple's
# C API over HarfBuzz (shaping), FreeType (outlines and metrics) and ICU
# (bidi and line breaking), drawing through CoreGraphics. Compiled against the
# SDK's CoreText headers so every function has Apple's signature.
#
# Linked as Apple ships it: Versions/A, current version 877.4, compatibility
# version 1, exporting only CT symbols.
#
#   userland/CoreText/build.sh
#     -> build/root/System/Library/Frameworks/CoreText.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreText"
OBJ="${FINCH_ROOT}/build/obj/CoreText"
SKIA_OBJ="${FINCH_ROOT}/build/obj/skia"
SKIA_SRC="${FINCH_ROOT}/build/src/skia"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/CoreText.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
CXX="$(xcrun -f clang++)"
log() { echo "==> $*"; }

for dep in CoreFoundation CoreGraphics; do
    [[ -f "${ROOT}/System/Library/Frameworks/${dep}.framework/${dep}" ]] || { echo "build ${dep} first" >&2; exit 1; }
done
[[ -f "${SKIA_OBJ}/libharfbuzz.a" ]] || "${FINCH_ROOT}/userland/skia/build.sh"

COMMON=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-common -fblocks
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations)
CXXFLAGS=("${COMMON[@]}" -std=c++20 -fno-exceptions -fno-rtti -Wno-missing-field-initializers
    -I"${SKIA_SRC}/third_party/externals/harfbuzz/src" -I"${FINCH_ROOT}/build/src/ICU/icu/icu4c/source/common"
    -DU_DISABLE_RENAMING=1 -DU_SHOW_CPLUSPLUS_API=0
    -I"${SKIA_SRC}/third_party/freetype2/include" -I"${SKIA_SRC}/third_party/externals/freetype/include"
    "-DFT_CONFIG_MODULES_H=<freetype-android/freetype/config/ftmodule.h>"
    "-DFT_CONFIG_OPTIONS_H=<freetype-android/freetype/config/ftoption.h>")

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/*.c; do
    "${CC}" "${COMMON[@]}" -std=c17 -c "$f" -o "${OBJ}/$(basename "${f%.c}").o"
done
for f in "${HERE}"/*.cpp; do
    "${CXX}" "${CXXFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.cpp}").o"
done

log "linking"
mkdir -p "${FW}/Versions/A"
"${CXX}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/CoreText.framework/Versions/A/CoreText \
    -current_version 877.4 -compatibility_version 1 \
    "${OBJ}"/*.o -o "${FW}/Versions/A/CoreText" \
    -Wl,-exported_symbols_list,"${HERE}/exports.txt" -Wl,-dead_strip \
    "${SKIA_OBJ}/libharfbuzz.a" "${SKIA_OBJ}/libfreetype2.a" "${SKIA_OBJ}/libpng.a" "${SKIA_OBJ}/libzlib.a" "${SKIA_OBJ}/libskia.a" \
    -F"${ROOT}/System/Library/Frameworks" -framework CoreFoundation -framework CoreGraphics -licucore -lc++
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/CoreText "${FW}/CoreText"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A CoreText com.apple.CoreText CoreText 1.0 877.4 English
codesign -f -s - -i com.apple.CoreText "${FW}/Versions/A/CoreText" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
