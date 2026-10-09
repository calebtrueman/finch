#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# ApplicationServices.framework: an umbrella with no code of its own,
# re-exporting the frameworks under it (docs/design/APPKIT.md). Apple's
# re-exports CoreGraphics, CoreText, ImageIO, ColorSync, CoreServices and
# its subframeworks (ATS, HIServices, ...); Finch's re-exports the ones Finch
# has, and gains the rest as they are written.
#
# Linked as Apple ships it: Versions/A, current version 66, compatibility
# version 1.
#
#   userland/ApplicationServices/build.sh
#     -> build/root/System/Library/Frameworks/ApplicationServices.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OBJ="${FINCH_ROOT}/build/obj/ApplicationServices"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/ApplicationServices.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

REEXPORTS=(CoreGraphics CoreText ImageIO)
for dep in "${REEXPORTS[@]}"; do
    [[ -f "${ROOT}/System/Library/Frameworks/${dep}.framework/${dep}" ]] || { echo "build ${dep} first" >&2; exit 1; }
done

log "linking"
rm -rf "${OBJ}" && mkdir -p "${OBJ}" "${FW}/Versions/A"
echo 'const double ApplicationServicesVersionNumber = 66.0;' > "${OBJ}/version.c"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices \
    -current_version 66 -compatibility_version 1 \
    "${OBJ}/version.c" -o "${FW}/Versions/A/ApplicationServices" \
    -F"${ROOT}/System/Library/Frameworks" $(printf -- '-Wl,-reexport_framework,%s ' "${REEXPORTS[@]}")
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/ApplicationServices "${FW}/ApplicationServices"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A ApplicationServices com.apple.ApplicationServices ApplicationServices 66 66 English
codesign -f -s - -i com.apple.ApplicationServices "${FW}/Versions/A/ApplicationServices" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
