#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Run a Mac app on the host against Finch's frameworks and a Finch window
# server, shown in the host viewer (tools/vz/finch-viewer).
#
#   tools/run-app.sh path/to/Some.app [WxH]
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$1"
SIZE="${2:-1280x800}"
R="${FINCH_ROOT}/build/root/System/Library"
SOCK="/tmp/finch-run-app.$$"
PORT=5990
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${APP}/Contents/Info.plist")"
"${FINCH_ROOT}/build/root/usr/libexec/finch-windowserver" --viewer "${PORT}" --size "${SIZE}" --scale 2 --socket "${SOCK}" &
SERVER=$!
trap 'kill ${SERVER} 2>/dev/null; rm -f "${SOCK}"' EXIT
sleep 0.5
"${FINCH_ROOT}/tools/vz/finch-viewer" "127.0.0.1:${PORT}" &
FINCH_WINDOWSERVER_SOCKET="${SOCK}" DYLD_FRAMEWORK_PATH="${R}/Frameworks:${R}/PrivateFrameworks" \
    FINCH_FONT_DIRS="${R}/Fonts" "${APP}/Contents/MacOS/${EXE}"
