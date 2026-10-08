#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# liblzma.5.dylib from upstream XZ Utils (liblzma is 0BSD). Apple doesn't
# publish its xz project for 26.4; it ships liblzma 5.4.3 (lzma_version_string()
# on the host), so that release is pinned by checksum. (5.4.3 predates the
# compromised 5.6.0 and 5.6.1 releases.)
#
# Built with upstream's configure as a static library, then linked as Apple
# ships it: install name /usr/lib/liblzma.5.dylib, current version 6.3,
# compatibility version 6, exporting exactly Apple's symbols (exports.txt).
#
#   userland/xz/build.sh   -> build/root/usr/lib/liblzma.5.dylib
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/xz"
VERSION=5.4.3
SHA256=1c382e0bc2e4e0af58398a903dd62fff7e510171d2de47a1ebe06d1528e9b7e9
URL="https://github.com/tukaani-project/xz/releases/download/v${VERSION}/xz-${VERSION}.tar.gz"
DL="${FINCH_ROOT}/build/src/upstream-dl/xz-${VERSION}.tar.gz"
SRC="${FINCH_ROOT}/build/src/xz-${VERSION}"
OBJ="${FINCH_ROOT}/build/obj/xz"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
log() { echo "==> $*"; }

if [[ "$(shasum -a 256 "${DL}" 2>/dev/null | cut -c1-64)" != "${SHA256}" ]]; then
    log "fetching xz ${VERSION}"
    mkdir -p "$(dirname "${DL}")"
    curl -sfL -o "${DL}" "${URL}"
    [[ "$(shasum -a 256 "${DL}" | cut -c1-64)" == "${SHA256}" ]] || { echo "xz: checksum mismatch" >&2; exit 1; }
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
        --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-lzma-links \
        --disable-scripts --disable-doc --disable-nls > configure.log 2>&1 \
        || { tail -20 configure.log; exit 1; }
fi
log "building"
make -s -j"$(sysctl -n hw.ncpu)" -C src/liblzma > make.log 2>&1 || { tail -20 make.log; exit 1; }

log "linking"
mkdir -p "${ROOT}/usr/lib"
"$(xcrun -f clang)" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /usr/lib/liblzma.5.dylib -current_version 6.3 -compatibility_version 6 \
    -Wl,-all_load src/liblzma/.libs/liblzma.a -Wl,-exported_symbols_list,"${HERE}/exports.txt" \
    -o "${ROOT}/usr/lib/liblzma.5.dylib"
ln -sfn liblzma.5.dylib "${ROOT}/usr/lib/liblzma.dylib"
codesign -f -s - "${ROOT}/usr/lib/liblzma.5.dylib" 2>/dev/null
mkdir -p "${ROOT}/usr/share/finch/licenses/xz"
cp "${SRC}/COPYING" "${SRC}/COPYING.0BSD" "${ROOT}/usr/share/finch/licenses/xz/" 2>/dev/null \
    || cp "${SRC}/COPYING" "${ROOT}/usr/share/finch/licenses/xz/"
log "installed build/root/usr/lib/liblzma.5.dylib"
