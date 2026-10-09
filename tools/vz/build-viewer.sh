#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build tools/vz/finch-viewer, the host viewer for finch-windowserver's TCP
# backend (signed ad hoc; not sandboxed, so no entitlements).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
xcrun swiftc -O -o "${here}/finch-viewer" \
    -import-objc-header "${here}/../../userland/WindowServer/FinchWSProtocol.h" \
    "${here}/finch-viewer.swift"
codesign -f -s - "${here}/finch-viewer"
echo "built ${here}/finch-viewer"
