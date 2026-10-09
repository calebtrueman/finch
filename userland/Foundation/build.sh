#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Foundation.framework: Finch's Foundation (docs/design/FOUNDATION.md),
# Objective-C over Finch's CoreFoundation, compiled against the SDK's
# Foundation headers so every method has Apple's signature.
#
# Linked as Apple ships it: Versions/C, current version 4424.1.255,
# compatibility version 300, re-exporting libobjc and CoreFoundation, and
# linking libicucore (measurement formats) and libxml2 (NSXMLParser) as
# Apple's does.
#
#   userland/Foundation/build.sh
#     -> build/root/System/Library/Frameworks/Foundation.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Foundation"
OBJ="${FINCH_ROOT}/build/obj/Foundation"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/Foundation.framework"
CFFW="${ROOT}/System/Library/Frameworks/CoreFoundation.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

[[ -f "${CFFW}/Versions/A/CoreFoundation" ]] || { echo "build CoreFoundation first: userland/CoreFoundation/build.sh" >&2; exit 1; }

# Foundation implements classes the SDK declares: the methods it doesn't have
# yet, and the protocol methods it gets from CoreFoundation, aren't errors.
CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g
    -fno-objc-arc -fobjc-weak -fobjc-exceptions -fblocks -fno-common
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-incomplete-implementation
    -Wno-objc-property-implementation -Wno-protocol -Wno-objc-protocol-method-implementation
    -Wno-deprecated-declarations -Wno-deprecated-implementations -Wno-objc-designated-initializers
    -Wno-objc-missing-super-calls -Wno-sign-compare -Wno-objc-method-access
    -I"${SDKROOT}/usr/include/libxml2")

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/*.m; do
    "${CC}" "${CFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.m}").o"
done

log "linking"
mkdir -p "${FW}/Versions/C"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation \
    -current_version 4424.1.255 -compatibility_version 300 \
    "${OBJ}"/*.o -o "${FW}/Versions/C/Foundation" -licucore -lxml2 \
    -F"${ROOT}/System/Library/Frameworks" -Wl,-reexport_framework,CoreFoundation -Wl,-reexport-lobjc -lSystem
ln -sfn C "${FW}/Versions/Current"
ln -sfn Versions/Current/Foundation "${FW}/Foundation"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" C Foundation com.apple.Foundation Foundation 6.9 4424.1.402 en_US
codesign -f -s - -i com.apple.Foundation "${FW}/Versions/C/Foundation" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
