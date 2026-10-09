#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build Rail.app, Fieldwork's launcher strip (docs/design/FIELDWORK.md).
#   userland/shell/Rail/build.sh -> build/root/System/Library/CoreServices/Rail.app
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FINCH_ROOT="$(cd "${HERE}/../../.." && pwd)"
APP="${FINCH_ROOT}/build/root/System/Library/CoreServices/Rail.app"
rm -rf "${APP}" && mkdir -p "${APP}/Contents/MacOS"
xcrun -sdk macosx clang -arch arm64e -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
    -Wno-unused-parameter -o "${APP}/Contents/MacOS/Rail" "${HERE}/main.m" -framework Cocoa
cp "${HERE}/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
codesign -f -s - "${APP}" 2>/dev/null
echo "built ${APP#"${FINCH_ROOT}/"}"
