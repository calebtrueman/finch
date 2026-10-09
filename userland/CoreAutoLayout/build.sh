#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreAutoLayout.framework (private): Auto Layout's view-independent half,
# as on macOS: NSLayoutConstraint and its autoresizing-mask and content-size
# kinds, the visual format parser, layout anchors, and Finch's constraint
# solver (FinchLayoutSolver.c, the Cassowary simplex). Foundation re-exports
# the classes apps bind (docs/design/APPKIT.md); AppKit links it directly
# for the solver.
#
# Linked as Apple's: Versions/A, current version 34, linking Foundation and
# CoreFoundation upward. Built after CoreFoundation and before Foundation
# (whose link re-exports symbols from it), so it links against the SDK's
# Foundation stub, which has the same install name as Finch's.
#
#   userland/CoreAutoLayout/build.sh
#     -> build/root/System/Library/PrivateFrameworks/CoreAutoLayout.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreAutoLayout"
OBJ="${FINCH_ROOT}/build/obj/CoreAutoLayout"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/PrivateFrameworks/CoreAutoLayout.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g
    -fno-objc-arc -fobjc-weak -fobjc-exceptions -fblocks -fno-common
    -Wall -Wextra -Werror -Wno-unused-command-line-argument -Wno-unused-parameter -Wno-incomplete-implementation
    -Wno-objc-property-implementation -Wno-protocol -Wno-objc-protocol-method-implementation
    -Wno-deprecated-declarations -Wno-deprecated-implementations -Wno-objc-designated-initializers
    -Wno-objc-missing-super-calls -Wno-sign-compare -Wno-objc-method-access -Wno-nullability -Wno-objc-protocol-property-synthesis
    -I"${HERE}")

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/*.m "${HERE}"/*.c; do
    "${CC}" "${CFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.*}").o"
done

log "linking"
mkdir -p "${FW}/Versions/A"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/PrivateFrameworks/CoreAutoLayout.framework/Versions/A/CoreAutoLayout \
    -current_version 34 -compatibility_version 1 \
    "${OBJ}"/*.o -o "${FW}/Versions/A/CoreAutoLayout" \
    -Wl,-upward_framework,Foundation -Wl,-upward_framework,CoreFoundation -lobjc
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/CoreAutoLayout "${FW}/CoreAutoLayout"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A CoreAutoLayout com.apple.CoreAutoLayout CoreAutoLayout 1.0 34 en
codesign -f -s - -i com.apple.CoreAutoLayout "${FW}/Versions/A/CoreAutoLayout" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
