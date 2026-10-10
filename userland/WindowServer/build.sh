#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-windowserver (docs/design/WINDOWSERVER.md): Finch's window server and
# compositor, over Skia (linked statically, from userland/skia/build.sh).
#
#   userland/WindowServer/build.sh   -> build/root/usr/libexec/finch-windowserver
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/WindowServer"
SKIA_OBJ="${FINCH_ROOT}/build/obj/skia"
SKIA_SRC="${FINCH_ROOT}/build/src/skia"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CXX="$(xcrun -f clang++)"
log() { echo "==> $*"; }

[[ -f "${SKIA_OBJ}/libskia.a" ]] || "${FINCH_ROOT}/userland/skia/build.sh"
DEFINES=($(cd "${SKIA_SRC}" && bin/gn desc "${SKIA_OBJ}" //:skia defines | grep -v SKIA_IMPLEMENTATION | sed 's/^/-D/'))

log "building"
mkdir -p "${ROOT}/usr/libexec"
"${CXX}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -std=c++20 -Os -g -fno-exceptions -fno-rtti \
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-missing-field-initializers -I"${SKIA_SRC}" "${DEFINES[@]}" \
    "${HERE}/server.cpp" -o "${ROOT}/usr/libexec/finch-windowserver" -Wl,-dead_strip \
    "${SKIA_OBJ}/libskia.a" "${SKIA_OBJ}/libskcms.a" "${SKIA_OBJ}/libzlib.a" -lz -lc++
codesign -f -s - -i org.finch.windowserver "${ROOT}/usr/libexec/finch-windowserver" 2>/dev/null
log "installed build/root/usr/libexec/finch-windowserver"
