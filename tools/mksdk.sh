#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Assemble build/sdk: the private headers Apple's open-source projects expect
# from Apple's internal SDK, collected from projects Apple publishes.
#
#   build/sdk/include      -> pass with -idirafter (public SDK headers win)
#   build/sdk/Frameworks   -> pass with -F (System.framework PrivateHeaders)
#
# Needs: tools/build-kernel.sh run once (for xnu's installed private headers)
#        tools/fetch-src.sh (for the header projects)
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${FINCH_ROOT}/build/src"
XNU_ROOT="${FINCH_ROOT}/build/xnu-work/fakeroot"
SDK="${FINCH_ROOT}/build/sdk"
INC="${SDK}/include"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ -d "${XNU_ROOT}/usr/local/include" ]] || die "no xnu headers; run tools/build-kernel.sh first"

rm -rf "${SDK}"
mkdir -p "${INC}" "${SDK}/Frameworks"

# copy_headers <src dir> <dest dir> [find args...]: copy matching headers, keeping layout.
copy_headers() {
    local from="$1" to="$2"
    shift 2
    [[ -d "${from}" ]] || die "missing ${from} (run tools/fetch-src.sh)"
    mkdir -p "${to}"
    (cd "${from}" && find . -name '*.h' "$@" -print0 | xargs -0 -I{} rsync -R -q {} "${to}/")
}

# xnu: private libsyscall/os headers, and System.framework private headers
# (reachable both as <System/sys/fsctl.h> and as <sys/fsctl.h>).
copy_headers "${XNU_ROOT}/usr/local/include" "${INC}"
sysfw="${XNU_ROOT}/System/Library/Frameworks/System.framework"
rsync -a "${sysfw}" "${SDK}/Frameworks/"
# xnu installs only Versions/B; add the standard top-level framework symlinks.
(cd "${SDK}/Frameworks/System.framework" && ln -sfn B Versions/Current \
    && ln -sfn Versions/Current/PrivateHeaders PrivateHeaders)
copy_headers "${sysfw}/Versions/B/PrivateHeaders" "${INC}"

chmod -R u+w "${SDK}"   # xnu installs headers read-only

# The AvailabilityVersions-generated internal headers use a different macro
# numbering than the public SDK's AvailabilityInternal.h and break any header
# using SPI_AVAILABLE. Without them, the public SDK defines SPI_AVAILABLE as a
# no-op annotation, which is all a build needs.
rm -f "${INC}/AvailabilityInternalPrivate.h" "${INC}/AvailabilityProhibitedInternal.h"

# Libc: private os/ headers (os/assumes.h, ...).
copy_headers "${SRC}/Libc/os" "${INC}/os" -maxdepth 1

# libplatform: private headers (_simple.h, os/*_private.h, ...).
copy_headers "${SRC}/libplatform/private" "${INC}"

# Libinfo: membershipPriv.h and other *Priv / *_private headers.
(cd "${SRC}/Libinfo" && find . \( -name '*Priv*.h' -o -name '*_private.h' \) -exec cp {} "${INC}/" \;)

# libutil, libmd: flat headers.
cp "${SRC}"/libutil/*.h "${INC}/"
cp "${SRC}"/libmd/libmd/*.h "${INC}/"

# CommonCrypto SPI: <CommonCrypto/CommonDigestSPI.h>.
copy_headers "${SRC}/CommonCrypto/include/Private" "${INC}/CommonCrypto" -maxdepth 1

# Third-party libraries macOS ships (the SDK has their .tbd stubs) but whose
# headers aren't in the public SDK. All permissively licensed; pinned upstream.
EXT="${FINCH_ROOT}/build/src/ext"
mkdir -p "${EXT}"
fetch() {   # fetch <url> <dest>: download once, cached in build/src/ext
    local cache="${EXT}/$(printf '%s' "$1" | shasum | cut -c1-12)-$(basename "$1")"
    [[ -f "${cache}" ]] || curl -sfL "$1" -o "${cache}" || die "download failed: $1"
    mkdir -p "$(dirname "$2")"
    cp "${cache}" "$2"
}
# libxo 1.7.5 (BSD-2-Clause): <libxo/xo.h>
fetch https://raw.githubusercontent.com/Juniper/libxo/1.7.5/libxo/xo.h "${INC}/libxo/xo.h"
# xz 5.8.4 liblzma API (0BSD): <lzma.h>, <lzma/*.h>
xz_api=https://raw.githubusercontent.com/tukaani-project/xz/v5.8.4/src/liblzma/api
fetch "${xz_api}/lzma.h" "${INC}/lzma.h"
for h in base bcj block check container delta filter hardware index index_hash lzma12 stream_flags version vli; do
    fetch "${xz_api}/lzma/${h}.h" "${INC}/lzma/${h}.h"
done
# FreeBSD 14.3 sha256.h / sha512.h (BSD-2-Clause): match macOS libmd's SHA*_ API.
for h in sha256 sha512; do
    fetch "https://raw.githubusercontent.com/freebsd/freebsd-src/release/14.3.0/sys/crypto/sha2/${h}.h" "${INC}/${h}.h"
done

echo "built ${SDK} ($(find "${INC}" -name '*.h' | wc -l | tr -d ' ') headers)"
