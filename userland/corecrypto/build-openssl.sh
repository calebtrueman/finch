#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the pinned open crypto backend into build/, without installing it
# into the host or Finch image. Keep any existing source checkout intact.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
src="${root}/build/src/openssl"
obj="${root}/build/obj/corecrypto-openssl"
revision=45e844fa2a14ec92d146bd8f5778ac130b6625fb
tag=openssl-3.5.9
if [[ ! -e "${src}" ]]; then
    git -c advice.detachedHead=false clone --depth 1 --branch "${tag}" \
        https://github.com/openssl/openssl.git "${src}"
fi
if [[ "$(git -C "${src}" rev-parse HEAD)" != "${revision}" ]]; then
    echo "OpenSSL source is at a different revision; leaving it untouched." >&2
    exit 1
fi
if [[ -n "$(git -C "${src}" status --porcelain --untracked-files=no)" ]]; then
    echo "OpenSSL source has local edits; leaving it untouched." >&2
    exit 1
fi
mkdir -p "${obj}"
cd "${obj}"
perl "${src}/Configure" --config="${root}/userland/corecrypto/openssl-arm64e.conf" \
    finch-arm64e no-shared no-tests no-apps no-docs no-module no-dso no-engine no-sock \
    --prefix="${root}/build/userland/openssl" --openssldir=/etc/ssl CC="xcrun -sdk macosx clang"
make -j"${JOBS:-6}" build_libs
echo "Built ${obj}/libcrypto.a from ${tag} (${revision})."
