#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Cocoa.framework: the umbrella most Mac apps link, with no code of its own
# (docs/design/APPKIT.md). Apple's re-exports AppKit and CoreData; Finch's
# re-exports AppKit (which brings Foundation), and CoreData once Finch has it.
#
# Linked as Apple ships it: Versions/A, current version 24, compatibility
# version 1.
#
#   userland/Cocoa/build.sh
#     -> build/root/System/Library/Frameworks/Cocoa.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OBJ="${FINCH_ROOT}/build/obj/Cocoa"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/Cocoa.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

[[ -f "${ROOT}/System/Library/Frameworks/AppKit.framework/AppKit" ]] || { echo "build AppKit first" >&2; exit 1; }

log "linking"
rm -rf "${OBJ}" && mkdir -p "${OBJ}" "${FW}/Versions/A"
echo 'const double CocoaVersionNumber = 24.0;' > "${OBJ}/version.c"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/Cocoa.framework/Versions/A/Cocoa \
    -current_version 24 -compatibility_version 1 \
    "${OBJ}/version.c" -o "${FW}/Versions/A/Cocoa" \
    -F"${ROOT}/System/Library/Frameworks" -F"${ROOT}/System/Library/PrivateFrameworks" \
    -Wl,-reexport_framework,AppKit
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/Cocoa "${FW}/Cocoa"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A Cocoa com.apple.Cocoa Cocoa 24 24 English
codesign -f -s - -i com.apple.Cocoa "${FW}/Versions/A/Cocoa" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
