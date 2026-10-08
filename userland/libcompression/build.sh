#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# libcompression.dylib: Finch's implementation of Apple's public compression
# API (compression.c) over open codecs. Apple's library is closed. The codecs:
#   LZFSE   Apple's open-source release (BSD-3-Clause), lzfse-1.0
#   LZ4     upstream lib/lz4.c (BSD-2-Clause), 1.10.0
#   Brotli  upstream (MIT), 1.1.0
#   zlib, liblzma   Finch's builds (/usr/lib/libz.1.dylib, liblzma.5.dylib)
# each pinned by checksum. Installed as Apple's: /usr/lib/libcompression.dylib,
# version 1.0.0, exporting the public API (exports.txt).
#
#   userland/libcompression/build.sh   -> build/root/usr/lib/libcompression.dylib
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/libcompression"
DLDIR="${FINCH_ROOT}/build/src/upstream-dl"
SRCDIR="${FINCH_ROOT}/build/src"
OBJ="${FINCH_ROOT}/build/obj/libcompression"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

# fetch <name> <dir in tarball> <url> <sha256>
fetch() {
    local dl="${DLDIR}/$1.tar.gz"
    if [[ "$(shasum -a 256 "${dl}" 2>/dev/null | cut -c1-64)" != "$4" ]]; then
        log "fetching $1"
        mkdir -p "${DLDIR}"
        curl -sfL -o "${dl}" "$3"
        [[ "$(shasum -a 256 "${dl}" | cut -c1-64)" == "$4" ]] || { echo "$1: checksum mismatch" >&2; exit 1; }
    fi
    if [[ ! -d "${SRCDIR}/$1" ]]; then
        tar -xzf "${dl}" -C "${SRCDIR}"
        [[ "$2" == "$1" ]] || mv "${SRCDIR}/$2" "${SRCDIR}/$1"
    fi
}
fetch lzfse-1.0 lzfse-lzfse-1.0 https://github.com/lzfse/lzfse/archive/refs/tags/lzfse-1.0.tar.gz \
    cf85f373f09e9177c0b21dbfbb427efaedc02d035d2aade65eb58a3cbf9ad267
fetch lz4-1.10.0 lz4-1.10.0 https://github.com/lz4/lz4/releases/download/v1.10.0/lz4-1.10.0.tar.gz \
    537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b
fetch brotli-1.1.0 brotli-1.1.0 https://github.com/google/brotli/archive/refs/tags/v1.1.0.tar.gz \
    e720a6ca29428b803f4ad165371771f5398faba397edf6778837a18599ea13ff
[[ -f "${SRCDIR}/xz-5.4.3/src/liblzma/api/lzma.h" ]] || "${FINCH_ROOT}/userland/xz/build.sh"

LZFSE="${SRCDIR}/lzfse-1.0/src"
LZ4="${SRCDIR}/lz4-1.10.0/lib"
BROTLI="${SRCDIR}/brotli-1.1.0/c"
CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -O2 -fvisibility=hidden)

log "compiling"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
objs=()
cc1() {   # cc1 <source> [flags...]
    local o="${OBJ}/$(echo "${1#"${SRCDIR}"/}" | tr / _).o"
    "${CC}" "${CFLAGS[@]}" "${@:2}" -c "$1" -o "${o}"
    objs+=("${o}")
}
for f in "${LZFSE}"/*.c; do
    [[ "$(basename "$f")" == lzfse_main.c ]] || cc1 "$f" -Wno-everything
done
cc1 "${LZ4}/lz4.c"
for f in "${BROTLI}"/common/*.c "${BROTLI}"/dec/*.c "${BROTLI}"/enc/*.c; do
    cc1 "$f" -I"${BROTLI}/include"
done
cc1 "${HERE}/compression.c" -Wall -Wextra -Werror -isystem "${LZFSE}" -I"${LZ4}" -I"${BROTLI}/include" \
    -I"${SRCDIR}/xz-5.4.3/src/liblzma/api" -fvisibility=default

log "linking"
mkdir -p "${ROOT}/usr/lib"
"${CC}" "${CFLAGS[@]}" -dynamiclib -install_name /usr/lib/libcompression.dylib \
    -current_version 1.0.0 -compatibility_version 1.0.0 "${objs[@]}" \
    -Wl,-exported_symbols_list,"${HERE}/exports.txt" \
    -L"${ROOT}/usr/lib" -llzma -lz -o "${ROOT}/usr/lib/libcompression.dylib"
codesign -f -s - "${ROOT}/usr/lib/libcompression.dylib" 2>/dev/null
for l in lzfse-1.0:LICENSE lz4-1.10.0:lib/LICENSE brotli-1.1.0:LICENSE; do
    mkdir -p "${ROOT}/usr/share/finch/licenses/${l%%:*}"
    cp "${SRCDIR}/${l%%:*}/${l#*:}" "${ROOT}/usr/share/finch/licenses/${l%%:*}/"
done
log "installed build/root/usr/lib/libcompression.dylib"
