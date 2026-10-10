#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# AudioToolbox.framework: Finch's. So far system sounds (AudioServices.c), silent until
# Finch has audio output.
#   userland/AudioToolbox/build.sh -> build/root/System/Library/Frameworks/AudioToolbox.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${FINCH_ROOT}/tools/build-small-framework.sh" \
    /System/Library/Frameworks/AudioToolbox.framework/Versions/A/AudioToolbox 1000 1 com.apple.audio.toolbox.AudioToolbox 1.14 \
    "${FINCH_ROOT}/userland/AudioToolbox/AudioServices.c" -- -framework CoreFoundation -framework CoreAudio
