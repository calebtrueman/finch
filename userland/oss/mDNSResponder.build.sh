#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# libsystem_dnssd.dylib (the DNS-SD client library) from mDNSResponder's
# mDNSShared client sources. Apple doesn't publish the macOS Xcode project,
# so this links the client sources as Apple ships the library: install name,
# version 2881.100.56, the libSystem umbrella, and Apple's export list
# (userland/oss/mDNSResponder/libsystem_dnssd.exports). Called by
# tools/build-oss.sh (SRC, OBJ, STAGE, SDKROOT, FINCH_*_CFLAGS).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)/mDNSResponder"
cd "${SRC}/mDNSShared"
rm -rf "${OBJ}"; mkdir -p "${OBJ}" "${STAGE}/usr/lib/system"

CC="xcrun -sdk macosx clang"
flags=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -fblocks
       -I. -I../mDNSCore
       -DAPPLE_OSX_mDNSResponder=1 -DMDNS_NO_STRICT=1 -D__APPLE_USE_RFC_3542=1
       ${FINCH_SDK_CFLAGS} -Wno-error)
objs=()
for f in dnssd_clientlib.c dnssd_clientstub.c dnssd_ipc.c dnssd_errstring.c; do
    ${CC} "${flags[@]}" -c "$f" -o "${OBJ}/${f%.c}.o"
    objs+=("${OBJ}/${f%.c}.o")
done
for f in "${HERE}"/*.c; do
    [[ -f "$f" ]] || continue
    ${CC} "${flags[@]}" -c "$f" -o "${OBJ}/finch_$(basename "${f%.c}").o"
    objs+=("${OBJ}/finch_$(basename "${f%.c}").o")
done

# Sub-libraries of libSystem link their siblings, not the umbrella.
${CC} -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib -nostdlib \
    -install_name /usr/lib/system/libsystem_dnssd.dylib \
    -compatibility_version 1 -current_version 2881.100.56 -umbrella System \
    -Wl,-exported_symbols_list,"${HERE}/libsystem_dnssd.exports" \
    "${objs[@]}" -L"${SDKROOT}/usr/lib/system" -ldyld -lcompiler_rt -lsystem_kernel -lsystem_platform \
    -lsystem_pthread -lsystem_malloc -lsystem_c -lsystem_blocks -ldispatch -lsystem_asl -lxpc \
    -Wl,-dead_strip_dylibs -o "${STAGE}/usr/lib/system/libsystem_dnssd.dylib"
echo "linked libsystem_dnssd.dylib from ${#objs[@]} objects"
