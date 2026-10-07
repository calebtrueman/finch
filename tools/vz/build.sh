#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build tools/vz/finch-vz (signed ad hoc with the virtualization entitlement).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
xcrun swiftc -O -o "${here}/finch-vz" "${here}/finch-vz.swift"
codesign -f -s - --entitlements "${here}/finch-vz.entitlements" "${here}/finch-vz"
echo "built ${here}/finch-vz"
