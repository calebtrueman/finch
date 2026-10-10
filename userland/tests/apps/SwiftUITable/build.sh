#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build SwiftUITable.app as Xcode would (swiftc against Apple's SDK, an Info.plist), for
# running unmodified on Finch's SwiftUI.
#   userland/tests/apps/SwiftUITable/build.sh -> build/userland/apps/SwiftUITable.app
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FINCH_ROOT="$(cd "${HERE}/../../../.." && pwd)"
APP="${FINCH_ROOT}/build/userland/apps/SwiftUITable.app"
rm -rf "${APP}" && mkdir -p "${APP}/Contents/MacOS"
xcrun -sdk macosx swiftc -target arm64e-apple-macos26.0 -O -parse-as-library \
    -o "${APP}/Contents/MacOS/SwiftUITable" "${HERE}/main.swift"
cp "${HERE}/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
codesign -f -s - --entitlements "${HERE}/../debug.entitlements" "${APP}" 2>/dev/null
echo "built ${APP#"${FINCH_ROOT}/"}"
