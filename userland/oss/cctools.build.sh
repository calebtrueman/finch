#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# libmacho.dylib (/usr/lib/system/libmacho.dylib) from cctools' libmacho
# sources, linked as Apple ships it: install name, version 1040, the
# libSystem umbrella and Apple's export list
# (userland/oss/cctools/libmacho.exports). Called by tools/build-oss.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)/cctools"
cd "${SRC}"
rm -rf "${OBJ}"; mkdir -p "${OBJ}" "${STAGE}/usr/lib/system"

CC="xcrun -sdk macosx clang"
flags=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -Iinclude
       ${FINCH_SDK_CFLAGS} -Wno-error -Wno-deprecated-declarations)
objs=()
for f in libmacho/*.c "${HERE}"/*.c; do
    [[ -f "$f" ]] || continue
    o="${OBJ}/$(basename "${f%.c}").o"
    ${CC} "${flags[@]}" -c "$f" -o "$o"
    objs+=("$o")
done

# Sub-libraries of libSystem link their siblings, not the umbrella (as
# Apple's: upward links to compiler_rt, malloc, c, kernel).
${CC} -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib -nostdlib \
    -install_name /usr/lib/system/libmacho.dylib \
    -compatibility_version 1 -current_version 1040 -umbrella System \
    -Wl,-exported_symbols_list,"${HERE}/libmacho.exports" \
    "${objs[@]}" -L"${SDKROOT}/usr/lib/system" -Wl,-upward-lcompiler_rt -Wl,-upward-lsystem_malloc \
    -ldyld -Wl,-upward-lsystem_c -Wl,-upward-lsystem_kernel \
    -o "${STAGE}/usr/lib/system/libmacho.dylib"
echo "linked libmacho.dylib from ${#objs[@]} objects"
