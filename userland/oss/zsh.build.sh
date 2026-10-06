#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build recipe for zsh-118 (zsh 5.9). Apple builds it with internal GNUSource
# makefiles; this runs the same configure flags directly (see the project's
# Makefile). Called by tools/build-oss.sh with SRC, OBJ, STAGE, SDKROOT and
# FINCH_SDK_CFLAGS set.
# --enable-pcre is omitted: the public SDK has no PCRE headers.
set -euo pipefail

mkdir -p "${OBJ}"
cd "${OBJ}"

export CC="xcrun -sdk macosx clang"
export CFLAGS="-arch arm64e -mmacosx-version-min=26.0 -O2 -isysroot ${SDKROOT}"
export CPPFLAGS="-DUSE_GETCWD ${FINCH_SDK_CFLAGS}"
export LDFLAGS="-arch arm64e -mmacosx-version-min=26.0 -isysroot ${SDKROOT}"

if [[ ! -f Makefile ]]; then
    # zsh 5.9's config.guess reports Apple Silicon as "arm" and its config.sub
    # predates "arm64", so configure as aarch64 and fix MACHTYPE below.
    "${SRC}/zsh/configure" --build=aarch64-apple-darwin --host=aarch64-apple-darwin \
        --prefix=/usr --bindir=/bin --sysconfdir=/private/etc \
        --with-tcsetpgrp --enable-multibyte --enable-unicode9 \
        --enable-max-function-depth=700 \
        --enable-etcdir=/private/etc --enable-zshenv=/private/etc/zshenv \
        --enable-zprofile=/private/etc/zprofile --enable-zshrc=/private/etc/zshrc
    sed -i '' 's/^#define MACHTYPE .*/#define MACHTYPE "arm64"/' config.h   # as on macOS
fi
make -j"$(sysctl -n hw.ncpu)"
make install.bin install.modules install.fns DESTDIR="${STAGE}"

# Apple's post-install: no versioned binary; system zprofile/zshrc.
rm -f "${STAGE}/bin/zsh-5.9"
mkdir -p "${STAGE}/private/etc"
install -m 0444 "${SRC}/zprofile" "${SRC}/zshrc" "${STAGE}/private/etc/"
