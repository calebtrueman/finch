#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the published CommonCrypto source (unmodified) against Finch's
# measured interfaces.
#   build-commoncrypto.sh                  local test library, linked to the
#                                          test corecrypto (abi-crypto.dylib)
#   build-commoncrypto.sh --install ROOT   ROOT/usr/lib/system/libcommonCrypto.dylib
#                                          for the image, linked as Apple's is
set -euo pipefail
install_root=""
if [[ "${1:-}" == --install ]]; then
    install_root="${2:?usage: build-commoncrypto.sh --install ROOT}"
fi
here="$(cd "$(dirname "$0")" && pwd)"
finch_root="$(cd "${here}/../.." && pwd)"
src="${finch_root}/build/src/CommonCrypto"
obj="${finch_root}/build/obj/CommonCrypto-finch"
out="${finch_root}/build/userland/CommonCrypto"
crypto="${finch_root}/build/userland/corecrypto/abi-crypto.dylib"
[[ -d "${src}" ]] || { echo 'Run tools/fetch-src.sh CommonCrypto first.' >&2; exit 1; }
make -C "${here}" abi-crypto
mkdir -p "${obj}/include/CommonCrypto" "${obj}/include/CommonNumerics" "${out}"
cp "${src}/include/"*.h "${src}/include/Private/"*.h "${obj}/include/CommonCrypto/"
cp "${src}/include/Private/CommonNumerics.h" "${src}/include/Private/CommonBaseXX.h" "${src}/include/Private/CommonCRC.h" "${obj}/include/CommonNumerics/"
flags=(-arch arm64e -mmacosx-version-min=26.0 -Os -fblocks -Wno-deprecated-declarations -Werror=implicit-function-declaration
 -I"${here}/compat" -I"${finch_root}/build/sdk/availability" -I"${obj}/include"
 -I"${src}/lib" -I"${src}/libcn" -idirafter "${finch_root}/build/sdk/include")
objects=()
for source in "${src}/lib/"*.c "${src}/libcn/"*.c; do
    name="$(basename "${source}" .c)"
    object="${obj}/${name}.o"
    xcrun clang "${flags[@]}" -c "${source}" -o "${object}"
    objects+=("${object}")
done
if [[ -n "${install_root}" ]]; then
    # Apple's dependencies, in Apple's order; no umbrella link (libSystem
    # links this library, not the other way round).
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    lib="${install_root}/usr/lib/system/libcommonCrypto.dylib"
    mkdir -p "$(dirname "${lib}")"
    xcrun clang -arch arm64e -mmacosx-version-min=26.0 -dynamiclib -nostdlib "${objects[@]}" \
        -L"${sdk}/usr/lib/system" -ldyld -lcompiler_rt -lsystem_kernel -lsystem_platform \
        -lsystem_malloc -lsystem_c -lsystem_blocks -ldispatch -lsystem_asl -lcorecrypto -lsystem_trace \
        -Wl,-exported_symbols_list,"${src}/exports.exp-in" -umbrella System \
        -install_name /usr/lib/system/libcommonCrypto.dylib -current_version 65535 -compatibility_version 1.0 \
        -o "${lib}"
    codesign -f -s - "${lib}"
    echo "Built ${lib}."
    exit 0
fi
xcrun clang -arch arm64e -dynamiclib -Wl,-not_for_dyld_shared_cache "${objects[@]}" "${crypto}" \
    -Wl,-exported_symbols_list,"${src}/exports.exp-in" \
    -install_name /usr/lib/system/libcommonCrypto.dylib -current_version 65535.0.0 -compatibility_version 1.0 \
    -o "${out}/libcommonCrypto.dylib"
crypto_id="$(xcrun otool -D "${crypto}" | tail -n 1)"
xcrun install_name_tool -change "${crypto_id}" '@loader_path/../corecrypto/abi-crypto.dylib' "${out}/libcommonCrypto.dylib"
codesign -f -s - "${out}/libcommonCrypto.dylib"
echo "Built ${out}/libcommonCrypto.dylib for local tests."
