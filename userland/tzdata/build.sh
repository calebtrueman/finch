#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The time-zone database, from IANA's tz releases (public domain), pinned
# by checksum: the release macOS 26.4 ships (2026c). IANA's zic, built for
# the host, compiles tzdata into /usr/share/zoneinfo. The files are "fat"
# (with the version 1 data), which CoreFoundation's CFTimeZone reads. macOS
# keeps them under /var/db/timezone/zoneinfo, where CF looks; Finch's rc
# links that to /usr/share/zoneinfo at boot.
#
#   userland/tzdata/build.sh   -> build/root/usr/share/zoneinfo
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION=2026c
DL="${FINCH_ROOT}/build/src/upstream-dl"
SRC="${FINCH_ROOT}/build/src/tz-${VERSION}"
OUT="${FINCH_ROOT}/build/root/usr/share/zoneinfo"
log() { echo "==> $*"; }

fetch() {   # fetch <file> <sha256>
    if [[ "$(shasum -a 256 "${DL}/$1" 2>/dev/null | cut -c1-64)" != "$2" ]]; then
        log "fetching $1"
        mkdir -p "${DL}"
        curl -sfL -o "${DL}/$1" "https://data.iana.org/time-zones/releases/$1"
        [[ "$(shasum -a 256 "${DL}/$1" | cut -c1-64)" == "$2" ]] || { echo "$1: checksum mismatch" >&2; exit 1; }
    fi
}
fetch "tzdata${VERSION}.tar.gz" e4a178a4477f3d0ea77cc31828ff72aa38feff8d61aa13e7e99e142e9d902be4
fetch "tzcode${VERSION}.tar.gz" b1cffc3ace4c4c7cd0efba2f7add86ec3d0b79da48bcf03582671fd3c8feace8
if [[ ! -f "${SRC}/zic.c" ]]; then
    rm -rf "${SRC}" && mkdir -p "${SRC}"
    tar -xzf "${DL}/tzdata${VERSION}.tar.gz" -C "${SRC}"
    tar -xzf "${DL}/tzcode${VERSION}.tar.gz" -C "${SRC}"
fi

log "building zic"
make -s -C "${SRC}" zic CC="xcrun clang" > "${SRC}/zic.log" 2>&1 || { tail -20 "${SRC}/zic.log"; exit 1; }

log "compiling zones"
rm -rf "${OUT}" && mkdir -p "${OUT}"
cd "${SRC}"
./zic -b fat -d "${OUT}" africa antarctica asia australasia europe northamerica southamerica etcetera backward factory
cp zone.tab zone1970.tab iso3166.tab leapseconds "${OUT}/"
echo "${VERSION}" > "${OUT}/+VERSION"
mkdir -p "${FINCH_ROOT}/build/root/usr/share/finch/licenses/tz"
cp LICENSE "${FINCH_ROOT}/build/root/usr/share/finch/licenses/tz/"
log "installed build/root/usr/share/zoneinfo ($(find "${OUT}" -type f | wc -l | tr -d ' ') files, tzdata ${VERSION})"
