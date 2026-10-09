#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# UniformTypeIdentifiers.framework: Finch's UTType (UTType.m's header comment),
# with the system's declared types in UTTypeTable.inc, compiled against the
# SDK's headers so every method has Apple's signature.
#
# Linked as Apple ships it: Versions/A, current version 709, compatibility version 1.
#
#   userland/UniformTypeIdentifiers/build.sh
#     -> build/root/System/Library/Frameworks/UniformTypeIdentifiers.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/UniformTypeIdentifiers"
OBJ="${FINCH_ROOT}/build/obj/UniformTypeIdentifiers"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/UniformTypeIdentifiers.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

[[ -f "${ROOT}/System/Library/Frameworks/Foundation.framework/Foundation" ]] || { echo "build Foundation first" >&2; exit 1; }

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g
    -fno-objc-arc -fobjc-exceptions -fblocks -fno-common
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-objc-property-implementation -Wno-nullability
    -Wno-incomplete-implementation -I"${HERE}")

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in UTType UTCoreTypes UTAdditions; do
    "${CC}" "${CFLAGS[@]}" -c "${HERE}/${f}.m" -o "${OBJ}/${f}.o"
done

log "linking"
mkdir -p "${FW}/Versions/A"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/UniformTypeIdentifiers.framework/Versions/A/UniformTypeIdentifiers \
    -current_version 709 -compatibility_version 1 \
    "${OBJ}"/*.o -o "${FW}/Versions/A/UniformTypeIdentifiers" \
    -F"${ROOT}/System/Library/Frameworks" -framework Foundation -framework CoreFoundation -lobjc -Wl,-no_warn_inits
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/UniformTypeIdentifiers "${FW}/UniformTypeIdentifiers"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A UniformTypeIdentifiers com.apple.UniformTypeIdentifiers UniformTypeIdentifiers 1.0 709 English
codesign -f -s - -i com.apple.UniformTypeIdentifiers "${FW}/Versions/A/UniformTypeIdentifiers" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
