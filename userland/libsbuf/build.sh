#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# libsbuf.dylib: FreeBSD's sbuf library (BSD-2-Clause: sys/kern/subr_sbuf.c and
# the userland part of subr_prf.c, as lib/libsbuf builds them), which apply, w
# and uptime use. Apple ships the same code with every function renamed
# sbuf_* -> usbuf_* (its <usbuf.h>), so it can't clash with the kernel's; the
# struct layout and flag values are FreeBSD's. Apple doesn't publish its copy
# for 26.4, so this builds FreeBSD's (pinned to the release Finch's libm uses)
# with Apple's renames generated from the SDK's usbuf.h.
#
# Linked as Apple ships it: install name /usr/lib/libsbuf.dylib, version 1.0.0,
# exporting exactly Apple's symbols (exports.txt).
#
#   userland/libsbuf/build.sh   -> build/root/usr/lib/libsbuf.dylib
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/libsbuf"
TAG=release/14.5.0
SRC="${FINCH_ROOT}/build/src/freebsd-sbuf"
OBJ="${FINCH_ROOT}/build/obj/libsbuf"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

if [[ "$(git -C "${SRC}" rev-parse HEAD 2>/dev/null || true)" != \
      "$(git -C "${SRC}" rev-parse -q --verify "${TAG}^{commit}" 2>/dev/null || echo none)" ]]; then
    log "fetching FreeBSD sbuf (${TAG})"
    rm -rf "${SRC}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${TAG}" --filter=blob:none --sparse \
        https://github.com/freebsd/freebsd-src.git "${SRC}"
    git -C "${SRC}" sparse-checkout set --no-cone /lib/libsbuf/ /sys/kern/subr_sbuf.c /sys/kern/subr_prf.c /sys/sys/sbuf.h
fi

mkdir -p "${OBJ}/include/sys"
cp "${SRC}/sys/sys/sbuf.h" "${OBJ}/include/sys/sbuf.h"
# FreeBSD's kernel <sys/ctype.h>; in userland, the C library's.
echo '#include <ctype.h>' > "${OBJ}/include/sys/ctype.h"
# Apple's renames, from the SDK's <usbuf.h>: #define sbuf_new usbuf_new, ...
grep -E '^#define[[:space:]]+sbuf[a-z_]*[[:space:]]+usbuf' "${SDKROOT}/usr/include/usbuf.h" > "${OBJ}/include/usbuf_names.h"

log "compiling"
for f in subr_sbuf subr_prf; do
    "${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -O2 \
        -include "${HERE}/freebsd_compat.h" -include "${OBJ}/include/usbuf_names.h" -I"${OBJ}/include" \
        -c "${SRC}/sys/kern/${f}.c" -o "${OBJ}/${f}.o"
done

log "linking"
mkdir -p "${ROOT}/usr/lib"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /usr/lib/libsbuf.dylib -current_version 1.0.0 -compatibility_version 1.0.0 \
    "${OBJ}/subr_sbuf.o" "${OBJ}/subr_prf.o" -Wl,-exported_symbols_list,"${HERE}/exports.txt" \
    -o "${ROOT}/usr/lib/libsbuf.dylib"
codesign -f -s - "${ROOT}/usr/lib/libsbuf.dylib" 2>/dev/null
log "installed build/root/usr/lib/libsbuf.dylib"
