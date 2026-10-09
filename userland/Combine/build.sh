#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Combine.framework, from OpenCombine (MIT), compiled as module Combine with library
# evolution so apps built against Apple's Combine link to it. Apple's Combine imports
# only Darwin and Swift (its Dispatch, RunLoop and Foundation integrations are in
# Foundation's overlay), so this is OpenCombine's core module alone; its
# Optional.Publisher and Result.Publisher, which OpenCombine leaves out wherever
# Apple's Combine exists, are kept. Its C++ helpers are linked in privately.
#   userland/Combine/build.sh -> build/root/System/Library/Frameworks/Combine.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Combine"
SRC="${FINCH_ROOT}/build/src/OpenCombine"
TAG=0.14.0
OBJ="${FINCH_ROOT}/build/obj/Combine"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/Combine.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
TARGET=arm64e-apple-macos26.0
log() { echo "==> $*"; }

if [[ "$(git -C "${SRC}" rev-parse HEAD 2>/dev/null || true)" != \
      "$(git -C "${SRC}" rev-parse -q --verify "${TAG}^{commit}" 2>/dev/null || echo none)" ]]; then
    log "fetching OpenCombine ${TAG}"
    rm -rf "${SRC}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${TAG}" https://github.com/OpenCombine/OpenCombine.git "${SRC}"
fi

rm -rf "${OBJ}" && mkdir -p "${OBJ}/src" "${OBJ}/helpers"
cp -R "${SRC}/Sources/OpenCombine/" "${OBJ}/src/"
python3 "${HERE}/adapt.py" "${OBJ}/src"
# Finch's own: the publishers OpenCombine lacks (Merge.swift and CombineLatest.swift come from gen.py)
cp "${HERE}"/Finch/*.swift "${OBJ}/src/"
cp "${SRC}/Sources/COpenCombineHelpers/include/COpenCombineHelpers.h" "${OBJ}/helpers/"
cat > "${OBJ}/helpers/module.modulemap" <<'MAP'
module COpenCombineHelpers {
    header "COpenCombineHelpers.h"
    export *
}
MAP

log "compiling"
xcrun clang++ -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -std=c++17 -O2 -fvisibility=hidden \
    -I"${OBJ}/helpers" -c "${SRC}/Sources/COpenCombineHelpers/COpenCombineHelpers.cpp" -o "${OBJ}/helpers.o"
"$(xcrun -f swiftc)" -c -wmo -module-name Combine -parse-as-library -enable-library-evolution \
    -target "${TARGET}" -sdk "${SDKROOT}" -swift-version 5 -O -I "${OBJ}/helpers" \
    -Xcc -fvisibility=hidden $(find "${OBJ}/src" -name '*.swift') -o "${OBJ}/Combine-swift.o" \
    -emit-module-interface-path "${OBJ}/Combine.swiftinterface"

log "linking"
mkdir -p "${FW}/Versions/A"
xcrun clang++ -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/Combine.framework/Versions/A/Combine \
    -current_version 3023 -compatibility_version 1 \
    "${OBJ}/Combine-swift.o" "${OBJ}/helpers.o" -o "${FW}/Versions/A/Combine" -L"${SDKROOT}/usr/lib/swift"
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/Combine "${FW}/Combine"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A Combine com.apple.Combine Combine 1.0 3023 English
codesign -f -s - -i com.apple.Combine "${FW}/Versions/A/Combine" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
