#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build recipe for ICU-76142.4.7: libicucore and its data, with Apple's own
# makefile (docs/design/COREFOUNDATION.md). Called by tools/build-oss.sh with
# SRC, OBJ, STAGE, SDKROOT and FINCH_SDK_CFLAGS set.
#
# The makefile expects Apple's internal SDK (macosx.internal) for the host
# tools it builds first (the data compilers); the public SDK serves both. Its
# private headers (<os/feature_private.h>) come from Finch's overlay, added
# through the makefile's isysroot variables, which every compile uses. Tools
# that expect ICU's own headers in that SDK (icuzdump) find the copies the
# makefile's installhdrs step has already staged.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
overlay="-idirafter ${FINCH_ROOT}/build/sdk/override ${FINCH_SDK_CFLAGS} -idirafter ${STAGE}/usr/local/include"

# The makefile's install target also copies CLDR and emoji files that aren't
# in the published source and that nothing on Finch reads, so this builds
# install's prerequisites and installs the runtime pieces itself: the library
# and the data file it loads from /usr/share/icu. (ICU's license is installed
# from userland/oss/ICU.notices.)
cd "${SRC}"
make installhdrs installapi icu icuhost -j"$(sysctl -n hw.ncpu)" \
    SDKROOT="${SDKROOT}" HOSTSDKPATH="${SDKROOT}" MACOS_BLDHOST_SDK_VERSION=26.4 \
    ISYSROOT="-isysroot ${SDKROOT} ${overlay}" HOSTISYSROOT="-isysroot ${SDKROOT} ${overlay}" \
    RC_ARCHS=arm64e OBJROOT="${OBJ}" DSTROOT="${STAGE}" SYMROOT="${OBJ}/sym"

vers=$(sed -n 's/^ICU_VERS = //p' makefile)
tzformat=$(sed -n 's/^TZDATA_FORMAT_STRING = "\(.*\)"/\1/p' makefile)
install -d "${STAGE}/usr/lib" "${STAGE}/usr/share/icu"
install -m 0755 "${OBJ}/libicucore.A.dylib" "${STAGE}/usr/lib/libicucore.A.dylib"
strip -x -u -r -S "${STAGE}/usr/lib/libicucore.A.dylib"
ln -fs libicucore.A.dylib "${STAGE}/usr/lib/libicucore.dylib"
install -m 0444 "${OBJ}/icuhost/data/out/icudt${vers}l.dat" "${STAGE}/usr/share/icu/"
printf '%s' "${tzformat}" > "${STAGE}/usr/share/icu/icutzformat.txt"
