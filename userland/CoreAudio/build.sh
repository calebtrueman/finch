#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreAudio.framework: Finch's. So far the object and property API, with no devices
# until Finch has an audio driver (AudioHardware.c).
#   userland/CoreAudio/build.sh -> build/root/System/Library/Frameworks/CoreAudio.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/CoreAudio.framework/Versions/A/CoreAudio 1 1 com.apple.audio.CoreAudio 5.0 \
    "${FINCH_ROOT}/userland/CoreAudio/AudioHardware.c" -- -framework CoreFoundation
