#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The terminfo database (/usr/share/terminfo), as macOS has it: compiled from the pinned
# ncurses project's misc/terminfo.src (userland/projects.txt) with tic, as Apple's
# ncurses project's run_tic step does. The host's tic writes the same format (ncurses 5,
# directories named by the first character's hex code, as on macOS).
#   userland/terminfo/build.sh -> build/root/usr/share/terminfo
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${FINCH_ROOT}/build/src/ncurses/ncurses/misc/terminfo.src"
OUT="${FINCH_ROOT}/build/root/usr/share/terminfo"
[[ -f "${SRC}" ]] || { echo "fetch ncurses first (tools/build-system.sh ncurses)" >&2; exit 1; }
rm -rf "${OUT}" && mkdir -p "${OUT}"
/usr/bin/tic -x -o "${OUT}" "${SRC}" 2>/dev/null
echo "==> installed build/root/usr/share/terminfo ($(find "${OUT}" -type f | wc -l | tr -d ' ') entries)"
