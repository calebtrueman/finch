#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build SwiftUIGallery.app as Xcode would (swiftc against Apple's SDK, an Info.plist), for
# running unmodified on Finch's SwiftUI.
#   userland/tests/apps/SwiftUIGallery/build.sh -> build/userland/apps/SwiftUIGallery.app
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FINCH_ROOT="$(cd "${HERE}/../../../.." && pwd)"
APP="${FINCH_ROOT}/build/userland/apps/SwiftUIGallery.app"
rm -rf "${APP}" && mkdir -p "${APP}/Contents/MacOS"
xcrun -sdk macosx swiftc -target arm64e-apple-macos26.0 -O -parse-as-library \
    -o "${APP}/Contents/MacOS/SwiftUIGallery" "${HERE}/main.swift"
cp "${HERE}/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
codesign -f -s - "${APP}" 2>/dev/null
echo "built ${APP#"${FINCH_ROOT}/"}"
