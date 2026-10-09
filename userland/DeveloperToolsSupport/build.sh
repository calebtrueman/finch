#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# DeveloperToolsSupport.framework: Finch's, in Swift, to Apple's ABI
# (DeveloperToolsSupport.swift). Built with library evolution, as Apple's is.
#
#   userland/DeveloperToolsSupport/build.sh
#     -> build/root/System/Library/Frameworks/DeveloperToolsSupport.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-swift-framework.sh" DeveloperToolsSupport 23.40.26 \
    "${FINCH_ROOT}/userland/DeveloperToolsSupport/DeveloperToolsSupport.swift" -- -framework Foundation
