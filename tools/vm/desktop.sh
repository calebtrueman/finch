#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Finch's desktop from the emulated M4, live in a window on the host: boots the VM with
# Finch's window server on the guest's tunnel UART (tools/vm/desktop.exp) and connects
# finch-viewer to it through QEMU's TCP port. Frames come over the line deflated; input goes
# back the same way. The apps named start in the VM.
#   tools/vm/desktop.sh [--size WxH] [APP ...]
#   e.g. tools/vm/desktop.sh /Applications/SwiftUIGallery.app/Contents/MacOS/SwiftUIGallery
# Environment: QEMUPORT (default 2100); DESKTOP_SECONDS to stop after that long;
# VIEWER_ARGS for finch-viewer (as --dump PATH --frames N, to save the display and quit).
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SIZE=1280x800
if [[ "${1:-}" == --size ]]; then SIZE="$2"; shift 2; fi
export QEMUPORT="${QEMUPORT:-2100}"
[[ -x "${FINCH_ROOT}/tools/vz/finch-viewer" ]] || "${FINCH_ROOT}/tools/vz/build-viewer.sh"
"${FINCH_ROOT}/tools/vz/finch-viewer" "127.0.0.1:${QEMUPORT}" --line ${VIEWER_ARGS:-} &
VIEWER=$!
trap 'kill ${VIEWER} 2>/dev/null || true' EXIT
"${FINCH_ROOT}/tools/vm/with-vm-lock.sh" expect "${FINCH_ROOT}/tools/vm/desktop.exp" "${SIZE}" "$@"
