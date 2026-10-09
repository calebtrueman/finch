#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Accessibility.framework: Finch's, Objective-C (Accessibility.m) with its Swift overlay
# (Accessibility.swift), to Apple's ABI.
#
#   userland/Accessibility/build.sh -> build/root/System/Library/Frameworks/Accessibility.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Accessibility"
exec "${FINCH_ROOT}/tools/build-swift-framework.sh" Accessibility 1 \
    "${HERE}/Accessibility.m" "${HERE}/Accessibility.swift" -- \
    -framework Foundation -framework CoreGraphics -framework CoreFoundation -lobjc
