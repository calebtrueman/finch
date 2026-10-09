#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreTransferable.framework: Finch's, in Swift, to Apple's ABI (CoreTransferable.swift).
#
#   userland/CoreTransferable/build.sh
#     -> build/root/System/Library/Frameworks/CoreTransferable.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-swift-framework.sh" CoreTransferable 7.1.9 \
    "${FINCH_ROOT}/userland/CoreTransferable/CoreTransferable.swift" -- \
    -framework Foundation -framework Combine -framework UniformTypeIdentifiers
