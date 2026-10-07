#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the published CommonCrypto source against Finch's measured interfaces.
# This creates a local test library; it does not change the boot image.
set -euo pipefail
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
xcrun clang -arch arm64e -dynamiclib -Wl,-not_for_dyld_shared_cache "${objects[@]}" "${crypto}" \
    -Wl,-exported_symbols_list,"${src}/exports.exp-in" \
    -install_name /usr/lib/system/libcommonCrypto.dylib -current_version 65535.0.0 -compatibility_version 1.0 \
    -o "${out}/libcommonCrypto.dylib"
crypto_id="$(xcrun otool -D "${crypto}" | tail -n 1)"
xcrun install_name_tool -change "${crypto_id}" '@loader_path/../corecrypto/abi-crypto.dylib' "${out}/libcommonCrypto.dylib"
codesign -f -s - "${out}/libcommonCrypto.dylib"
echo "Built ${out}/libcommonCrypto.dylib for local tests."
