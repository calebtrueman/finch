#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build Hello.app as Xcode would (clang, ibtool, an Info.plist) for running unmodified on Finch.
#   userland/tests/apps/Hello/build.sh -> build/userland/apps/Hello.app
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FINCH_ROOT="$(cd "${HERE}/../../../.." && pwd)"
APP="${FINCH_ROOT}/build/userland/apps/Hello.app"
rm -rf "${APP}" && mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
xcrun -sdk macosx clang -arch arm64e -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Werror \
    -o "${APP}/Contents/MacOS/Hello" "${HERE}/main.m" "${HERE}/AppDelegate.m" -framework Cocoa
xcrun ibtool --compile "${APP}/Contents/Resources/MainMenu.nib" "${HERE}/MainMenu.xib"
cp "${HERE}/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"
codesign -f -s - "${APP}" 2>/dev/null
echo "built ${APP#"${FINCH_ROOT}/"}"
