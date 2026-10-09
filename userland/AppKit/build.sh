#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AppKit.framework: Finch's AppKit (docs/design/APPKIT.md), Objective-C over
# Finch's Foundation, CoreGraphics, CoreText and window server, compiled
# against the SDK's AppKit headers so every method has Apple's signature.
#
# Linked as Apple ships it: Versions/C, current version 2685.50.120,
# compatibility version 45, re-exporting Foundation, ApplicationServices and
# UIFoundation.
#
#   userland/AppKit/build.sh
#     -> build/root/System/Library/Frameworks/AppKit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/AppKit"
OBJ="${FINCH_ROOT}/build/obj/AppKit"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/AppKit.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

for dep in Frameworks/Foundation Frameworks/ApplicationServices PrivateFrameworks/UIFoundation; do
    [[ -f "${ROOT}/System/Library/${dep}.framework/${dep##*/}" ]] || { echo "build ${dep##*/} first" >&2; exit 1; }
done

# As Foundation: the SDK declares more than Finch implements so far.
CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g
    -fno-objc-arc -fobjc-weak -fobjc-exceptions -fblocks -fno-common
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-incomplete-implementation
    -Wno-objc-property-implementation -Wno-protocol -Wno-objc-protocol-method-implementation
    -Wno-deprecated-declarations -Wno-deprecated-implementations -Wno-objc-designated-initializers
    -Wno-objc-missing-super-calls -Wno-sign-compare -Wno-objc-method-access
    -Wno-objc-protocol-property-synthesis -Wno-nullability -Wno-atomic-property-with-user-defined-accessor
    -I"${HERE}" -I"${FINCH_ROOT}/userland")

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/*.m; do
    "${CC}" "${CFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.m}").o"
done

log "linking"
mkdir -p "${FW}/Versions/C"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit \
    -current_version 2685.50.120 -compatibility_version 45 \
    "${OBJ}"/*.o -o "${FW}/Versions/C/AppKit" \
    -F"${ROOT}/System/Library/Frameworks" -F"${ROOT}/System/Library/PrivateFrameworks" \
    -Wl,-reexport_framework,Foundation -Wl,-reexport_framework,ApplicationServices \
    -Wl,-reexport_framework,UIFoundation -framework CoreFoundation -lobjc
ln -sfn C "${FW}/Versions/Current"
ln -sfn Versions/Current/AppKit "${FW}/AppKit"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" C AppKit com.apple.AppKit AppKit 6.9 2685.50.120 English
codesign -f -s - -i com.apple.AppKit "${FW}/Versions/C/AppKit" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
