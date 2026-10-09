#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# UIFoundation.framework (private): the half of AppKit that Apple shares with
# UIKit, which AppKit re-exports (docs/design/APPKIT.md): fonts, paragraph
# styles, shadows, text attachments, string drawing and the text system.
# Objective-C over Finch's Foundation, CoreText and CoreGraphics, compiled
# against the SDK's AppKit headers so every method has Apple's signature.
#
# Linked as Apple ships it: Versions/A, current version 1018.1,
# compatibility version 1.
#
#   userland/UIFoundation/build.sh
#     -> build/root/System/Library/PrivateFrameworks/UIFoundation.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/UIFoundation"
OBJ="${FINCH_ROOT}/build/obj/UIFoundation"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/PrivateFrameworks/UIFoundation.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

for dep in Foundation CoreGraphics CoreText; do
    [[ -f "${ROOT}/System/Library/Frameworks/${dep}.framework/${dep}" ]] || { echo "build ${dep} first" >&2; exit 1; }
done

# As Foundation: the SDK declares more than Finch implements so far.
CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g
    -fno-objc-arc -fobjc-weak -fobjc-exceptions -fblocks -fno-common
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-incomplete-implementation
    -Wno-objc-property-implementation -Wno-protocol -Wno-objc-protocol-method-implementation
    -Wno-deprecated-declarations -Wno-deprecated-implementations -Wno-objc-designated-initializers
    -Wno-objc-missing-super-calls -Wno-sign-compare -Wno-objc-method-access
    -I"${HERE}" -I"${FINCH_ROOT}/userland")

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/*.m; do
    "${CC}" "${CFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.m}").o"
done

log "linking"
mkdir -p "${FW}/Versions/A"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/PrivateFrameworks/UIFoundation.framework/Versions/A/UIFoundation \
    -current_version 1018.1 -compatibility_version 1 \
    "${OBJ}"/*.o -o "${FW}/Versions/A/UIFoundation" \
    -F"${ROOT}/System/Library/Frameworks" -framework Foundation -framework CoreFoundation \
    -framework CoreGraphics -framework CoreText -lobjc
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/UIFoundation "${FW}/UIFoundation"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A UIFoundation com.apple.UIFoundation UIFoundation 1.0 1018.1 English
codesign -f -s - -i com.apple.UIFoundation "${FW}/Versions/A/UIFoundation" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
