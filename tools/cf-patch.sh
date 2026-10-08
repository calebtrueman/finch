#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Fold edits made in build/src/swift-corelibs-foundation into the last
# patch of userland/CoreFoundation/patches (keeping its header), so the
# working tree is again "the pinned source + the patch series", which
# userland/CoreFoundation/build.sh checks before it builds.
#
#   tools/cf-patch.sh
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${FINCH_ROOT}/build/src/swift-corelibs-foundation"
P="${FINCH_ROOT}/userland/CoreFoundation/patches"
last="$(ls "${P}"/*.patch | tail -1)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
head -n "$(grep -n '^diff --git' "${last}" | head -1 | cut -d: -f1)" "${last}" | sed '$d' > "${tmp}/header"
git -C "${SRC}" diff --name-only > "${tmp}/files"
while read -r f; do mkdir -p "${tmp}/save/$(dirname "$f")"; cp "${SRC}/$f" "${tmp}/save/$f"; done < "${tmp}/files"
git -C "${SRC}" checkout -q -- .
for p in "${P}"/*.patch; do [[ "$p" == "${last}" ]] || git -C "${SRC}" apply "$p"; done
git -C "${SRC}" add -A
while read -r f; do cp "${tmp}/save/$f" "${SRC}/$f"; done < "${tmp}/files"
{ cat "${tmp}/header"; git -C "${SRC}" diff; } > "${last}"
git -C "${SRC}" reset -q
git -C "${SRC}" apply -R --check "${last}"
echo "updated $(basename "${last}")"
