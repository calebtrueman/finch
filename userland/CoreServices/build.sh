#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreServices.framework: an umbrella with no code of its own. Apple's
# re-exports CoreFoundation, CFNetwork and its subframeworks (LaunchServices,
# CarbonCore, AE, Metadata, OSServices, FSEvents, ...); Finch's re-exports
# what Finch has, and gains the rest as they are written.
#
# Linked as Apple ships it: Versions/A, current version 1226, compatibility version 1.
#
#   userland/CoreServices/build.sh -> build/root/System/Library/Frameworks/CoreServices.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OBJ="${FINCH_ROOT}/build/obj/CoreServices"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/CoreServices.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

REEXPORTS=(CoreFoundation)
log "linking"
rm -rf "${OBJ}" && mkdir -p "${OBJ}" "${FW}/Versions/A"
echo 'const double CoreServicesVersionNumber = 1226.0;' > "${OBJ}/version.c"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices \
    -current_version 1226 -compatibility_version 1 "${OBJ}/version.c" -o "${FW}/Versions/A/CoreServices" \
    -F"${ROOT}/System/Library/Frameworks" $(printf -- '-Wl,-reexport_framework,%s ' "${REEXPORTS[@]}")
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/CoreServices "${FW}/CoreServices"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A CoreServices com.apple.CoreServices CoreServices 1226 1226 English
codesign -f -s - -i com.apple.CoreServices "${FW}/Versions/A/CoreServices" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
