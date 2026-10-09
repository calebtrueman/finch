#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The Swift runtime: libswiftCore.dylib, libswift_Concurrency.dylib and
# libswiftSwiftOnoneSupport, built from Swift's open source (Apache 2.0) with
# its standalone runtime build (Runtimes/Core), and the supplemental
# libraries Apple ships beside them (Runtimes/Supplemental: Observation,
# _StringProcessing with _RegexParser and RegexBuilder, Synchronization,
# Distributed, _Volatile, Runtime). Finch's libobjc links libswiftCore, as Apple's does
# (upward, delay-loaded: only Swift code brings it in), and Swift programs
# need it, so Finch ships an open one instead of the closed build the base
# image carries.
#
# The source is pinned to the release matching Xcode's Swift compiler, which
# builds it (the standard library needs a compiler of its own version).
# Runtimes/Core targets CMake 3.29-4.0 (its nested .swiftmodule layout
# breaks under CMake 4.1's policy CMP0195), so a pinned CMake 3.31 runs from
# a private venv in build/tools.
#
# The Darwin overlays (ObjectiveC, Dispatch, Foundation's neighbours) are
# userland/swift/overlays.sh, which runs after this.
#
#   userland/swift/build.sh   -> build/root/usr/lib/swift/libswiftCore.dylib, ...
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG=swift-6.3.1-RELEASE
SRC="${FINCH_ROOT}/build/src/swift"
OBJ="${FINCH_ROOT}/build/obj/swift-core"
SUPOBJ="${FINCH_ROOT}/build/obj/swift-supplemental"
STRSRC="${FINCH_ROOT}/build/src/swift-experimental-string-processing"
ROOT="${FINCH_ROOT}/build/root"
CMAKE_VERSION=3.31.6
VENV="${FINCH_ROOT}/build/tools/cmake3"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
log() { echo "==> $*"; }

swiftc_version=$(xcrun swiftc --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p')
[[ "swift-${swiftc_version}-RELEASE" == "${TAG}" ]] \
    || { echo "Xcode's Swift is ${swiftc_version}; this builds ${TAG} (update TAG with Xcode)" >&2; exit 1; }

if [[ "$("${VENV}/bin/cmake" --version 2>/dev/null | head -1)" != "cmake version ${CMAKE_VERSION}" ]]; then
    log "installing CMake ${CMAKE_VERSION} into build/tools"
    python3 -m venv "${VENV}"
    "${VENV}/bin/pip" install -q "cmake==${CMAKE_VERSION}"
fi
if [[ "$(git -C "${SRC}" rev-parse HEAD 2>/dev/null || true)" != \
      "$(git -C "${SRC}" rev-parse -q --verify "${TAG}^{commit}" 2>/dev/null || echo none)" ]]; then
    log "fetching ${TAG} (runtime sources)"
    rm -rf "${SRC}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${TAG}" --filter=blob:none --sparse \
        https://github.com/swiftlang/swift.git "${SRC}"
    git -C "${SRC}" sparse-checkout set Runtimes stdlib include cmake utils lib/Demangling lib/Threading
fi
for p in "${FINCH_ROOT}"/userland/swift/patches/*.patch; do
    [[ -e "${p}" ]] || continue
    git -C "${SRC}" apply -R --check "${p}" 2>/dev/null || {
        log "applying $(basename "${p}")"
        git -C "${SRC}" apply "${p}"
    }
done
# _StringProcessing's sources live in their own repository, at the same tag.
# Resync.cmake finds it next to the Swift checkout.
if [[ "$(git -C "${STRSRC}" rev-parse HEAD 2>/dev/null || true)" != \
      "$(git -C "${STRSRC}" rev-parse -q --verify "${TAG}^{commit}" 2>/dev/null || echo none)" ]]; then
    log "fetching swift-experimental-string-processing ${TAG}"
    rm -rf "${STRSRC}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${TAG}" \
        https://github.com/swiftlang/swift-experimental-string-processing.git "${STRSRC}"
fi
# Runtimes/ copies the standard library's sources in from stdlib/ (temporary
# upstream arrangement; see Runtimes/Readme.md).
(cd "${SRC}/Runtimes" && "${VENV}/bin/cmake" -P Resync.cmake >/dev/null)

log "configuring"
mkdir -p "${OBJ}"
# Apple's shipped runtime has the SIMD vector types, backtracing, environment
# support, the back-deployment symbols, os_signpost tracing and the
# Concurrency runtime; the configuration's Apple defaults leave those off.
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=YES
    -DCMAKE_C_COMPILER="$(xcrun -f clang)" -DCMAKE_CXX_COMPILER="$(xcrun -f clang++)"
    -DCMAKE_Swift_COMPILER="$(xcrun -f swiftc)" -DCMAKE_Swift_COMPILER_TARGET=arm64e-apple-macos26.0
    -DCMAKE_OSX_ARCHITECTURES=arm64e -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_SYSROOT="${SDKROOT}"
    -DCMAKE_INSTALL_NAME_DIR=/usr/lib/swift -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=YES)
"${VENV}/bin/cmake" -S "${SRC}/Runtimes/Core" -B "${OBJ}" "${COMMON[@]}" \
    -DSwiftCore_ENABLE_CONCURRENCY=ON -DSwiftCore_ENABLE_VECTOR_TYPES=ON -DSwiftCore_ENABLE_BACKTRACING=ON \
    -DSwiftCore_ENABLE_ENVIRONMENT=ON -DSwiftCore_ENABLE_BACKDEPLOYMENT_SUPPORT=ON \
    -DSwiftCore_ENABLE_STDLIB_TRACING=ON \
    > "${OBJ}/configure.log" 2>&1 || { tail -20 "${OBJ}/configure.log"; exit 1; }
log "building"
ninja -C "${OBJ}" > "${OBJ}/build.log" 2>&1 || { grep -m20 'error:' "${OBJ}/build.log"; exit 1; }

# The supplemental libraries build as separate projects against the core
# build's CMake package. (Differentiation needs the Darwin overlay's tgmath,
# which Apple's SDK now builds; Apple ships no libswift_Differentiation.)
for p in StringProcessing Synchronization Observation Distributed Volatile Runtime; do
    log "building Supplemental/${p}"
    mkdir -p "${SUPOBJ}/${p}"
    extra_swift_flags=""
    [[ "${p}" == Runtime ]] && extra_swift_flags="-DFINCH_RUNTIME"
    "${VENV}/bin/cmake" -S "${SRC}/Runtimes/Supplemental/${p}" -B "${SUPOBJ}/${p}" "${COMMON[@]}" \
        -DCMAKE_Swift_FLAGS="${extra_swift_flags}" \
        -DSwiftCore_DIR="${OBJ}/cmake/SwiftCore" -DSwift${p}_PATH_TO_SWIFT_RUNTIME_HEADERS="${OBJ}/include" \
        > "${SUPOBJ}/${p}/configure.log" 2>&1 || { tail -20 "${SUPOBJ}/${p}/configure.log"; exit 1; }
    ninja -C "${SUPOBJ}/${p}" > "${SUPOBJ}/${p}/build.log" 2>&1 \
        || { grep -m20 'error:' "${SUPOBJ}/${p}/build.log"; exit 1; }
done

mkdir -p "${ROOT}/usr/lib/swift"
for lib in "${OBJ}"/{Core/libswiftCore,SwiftOnoneSupport/libswiftSwiftOnoneSupport,Concurrency/libswift_Concurrency}.dylib \
           "${SUPOBJ}"/StringProcessing/{_RegexParser/libswift_RegexParser,_StringProcessing/libswift_StringProcessing,RegexBuilder/libswiftRegexBuilder}.dylib \
           "${SUPOBJ}"/{Synchronization/libswiftSynchronization,Observation/libswiftObservation,Distributed/libswiftDistributed,Volatile/libswift_Volatile,Runtime/libswiftRuntime}.dylib; do
    install -m 0755 "${lib}" "${ROOT}/usr/lib/swift/"
    codesign -f -s - "${ROOT}/usr/lib/swift/$(basename "${lib}")" 2>/dev/null
done
mkdir -p "${ROOT}/usr/share/finch/licenses/Swift" "${ROOT}/usr/share/finch/licenses/swift-experimental-string-processing"
cp "${SRC}/LICENSE.txt" "${ROOT}/usr/share/finch/licenses/Swift/"
cp "${STRSRC}/LICENSE.txt" "${ROOT}/usr/share/finch/licenses/swift-experimental-string-processing/"
log "installed build/root/usr/lib/swift: $(otool -D "${ROOT}/usr/lib/swift/libswiftCore.dylib" | tail -1)"
