#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# libxo.dylib from upstream libxo (Juniper Networks, BSD-2-Clause), which
# df, wc, w, uptime and last use for --libxo output. Apple doesn't publish its
# copy for 26.4; it ships libxo 1.6.0 (xo_version on the host), so that
# release is pinned by checksum.
#
# Built with upstream's configure as a static library, then linked as Apple
# ships it: install name /usr/lib/libxo.dylib, version 1.0.0, linking only
# libSystem and exporting exactly Apple's symbols (exports.txt).
#
#   userland/libxo/build.sh   -> build/root/usr/lib/libxo.dylib
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/libxo"
VERSION=1.6.0
SHA256=9f2f276d7a5f25ff6fbfc0f38773d854c9356e7f985501627d0c0ee336c19006
URL="https://github.com/Juniper/libxo/releases/download/${VERSION}/libxo-${VERSION}.tar.gz"
DL="${FINCH_ROOT}/build/src/upstream-dl/libxo-${VERSION}.tar.gz"
SRC="${FINCH_ROOT}/build/src/libxo-${VERSION}"
OBJ="${FINCH_ROOT}/build/obj/libxo"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
log() { echo "==> $*"; }

if [[ "$(shasum -a 256 "${DL}" 2>/dev/null | cut -c1-64)" != "${SHA256}" ]]; then
    log "fetching libxo ${VERSION}"
    mkdir -p "$(dirname "${DL}")"
    curl -sfL -o "${DL}" "${URL}"
    [[ "$(shasum -a 256 "${DL}" | cut -c1-64)" == "${SHA256}" ]] || { echo "libxo: checksum mismatch" >&2; exit 1; }
fi
if [[ ! -f "${SRC}/configure" ]]; then
    rm -rf "${SRC}" && mkdir -p "$(dirname "${SRC}")"
    tar -xzf "${DL}" -C "$(dirname "${SRC}")"
fi

log "configuring"
mkdir -p "${OBJ}" && cd "${OBJ}"
if [[ ! -f Makefile ]]; then
    CC="$(xcrun -f clang)" CFLAGS="-arch arm64e -mmacosx-version-min=26.0 -isysroot ${SDKROOT} -O2" \
        "${SRC}/configure" --host=aarch64-apple-darwin --enable-static --disable-shared \
        --disable-gettext --disable-libxo-options > configure.log 2>&1 \
        || { tail -20 configure.log; exit 1; }
fi
log "building"
make -s -j"$(sysctl -n hw.ncpu)" -C libxo > make.log 2>&1 || { tail -20 make.log; exit 1; }

log "linking"
mkdir -p "${ROOT}/usr/lib"
# xo_error_hv(), which Apple's copy has and upstream 1.6.0 doesn't.
"$(xcrun -f clang)" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -O2 -c \
    "${HERE}/xo_finch.c" -o xo_finch.o
"$(xcrun -f clang)" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib xo_finch.o \
    -install_name /usr/lib/libxo.dylib -current_version 1.0.0 -compatibility_version 1.0.0 \
    -Wl,-all_load libxo/.libs/libxo.a -Wl,-exported_symbols_list,"${HERE}/exports.txt" \
    -o "${ROOT}/usr/lib/libxo.dylib"
codesign -f -s - "${ROOT}/usr/lib/libxo.dylib" 2>/dev/null
mkdir -p "${ROOT}/usr/share/finch/licenses/libxo"
cp "${SRC}/Copyright" "${ROOT}/usr/share/finch/licenses/libxo/" 2>/dev/null \
    || cp "${SRC}/LICENSE" "${ROOT}/usr/share/finch/licenses/libxo/"
log "installed build/root/usr/lib/libxo.dylib"
