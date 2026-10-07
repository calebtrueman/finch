#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build dyld_shared_cache_builder (a host tool) from Apple's dyld source.
#
# Apple's Xcode target can't be built from the published source: it depends on
# SharedCacheLinker.framework, whose ld/ sources aren't published. The builder
# only calls into it for two optional products (stub dylibs and Swift
# prespecialization), so Finch compiles the builder's own sources directly
# (tools/dsc/sources.txt, taken from Xcode's build plan) and links a stand-in
# for the one linker entry point (tools/dsc/finch_missing.cpp).
#
#   tools/dsc/build-builder.sh      -> build/tools/dyld_shared_cache_builder
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${FINCH_ROOT}/build/src/dyld"
SDK="${FINCH_ROOT}/build/sdk"
OBJ="${FINCH_ROOT}/build/obj/dsc-builder"
OUT="${FINCH_ROOT}/build/tools/dyld_shared_cache_builder"
LOG="${FINCH_ROOT}/build/logs/dsc-builder.log"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
[[ -d "${SRC}" ]] || { echo "error: ${SRC} missing (tools/fetch-src.sh dyld)" >&2; exit 1; }
[[ -d "${SDK}" ]] || { echo "error: ${SDK} missing (tools/mksdk.sh)" >&2; exit 1; }
make -s -C "${FINCH_ROOT}/userland/CrashReporterClient" >/dev/null
# Finch patches to the dyld checkout (idempotent), as tools/build-oss.sh does.
for p in "${FINCH_ROOT}/tools/dsc/patches"/*.patch; do
    if git -C "${SRC}" apply --check "$p" 2>/dev/null; then
        git -C "${SRC}" apply "$p"
    elif ! git -C "${SRC}" apply --check --reverse "$p" 2>/dev/null; then
        echo "error: patch does not apply: $p" >&2; exit 1
    fi
done
mkdir -p "${OBJ}" "$(dirname "${OUT}")" "$(dirname "${LOG}")"

common=(-arch arm64 -mmacosx-version-min=14.0 -isysroot "${SDKROOT}" -Os -g
    -fvisibility=hidden -fno-common -DINTERNAL_BUILD=1
    -Wno-deprecated-declarations -Wno-unused-but-set-variable -Wno-nullability-completeness)
# Finch's private SDK first (as for libSystem projects), then the source tree.
GEN="${OBJ}/generated"
mkdir -p "${GEN}/System"
incs=(-include "${FINCH_ROOT}/tools/dsc/prelude.h" -I"${GEN}" -I"${FINCH_ROOT}/tools/dsc/include"
    -I"${SDK}/override" -I"${SDK}/availability" -F"${SDK}/Frameworks")
for d in include lsl dyld common framework mach_o mach_o_writer cache_builder shared_cache_linker \
         libdyld libdyld_introspection other-tools shared_cache_runtime; do
    incs+=(-iquote "${SRC}/${d}" -I"${SRC}/${d}")
done
incs+=(-I"${SRC}/include/mach-o" -idirafter "${SDK}/include" -F"${SDKROOT}/System/Library/PrivateFrameworks")

flags_for() {   # target -> extra flags
    case "$1" in
    dyld_shared_cache_builder)
        echo "-DBUILDING_CACHE_BUILDER=1 -DBUILDING_MACHO_WRITER=1 -DBUILDING_EMBEDDED_SHARED_CACHE_BUILDER=1" ;;
    *) echo "" ;;
    esac
}

: > "${LOG}"

# Generated headers, as Apple's build scripts make them (build-scripts/).
# <System/atexit.h> is Libc's private atexit header.
ln -sf "${FINCH_ROOT}/build/src/Libc/stdlib/FreeBSD/atexit.h" "${GEN}/System/atexit.h"
# <SharedCacheLinker/SharedCacheLinker.h>, as the framework would provide it.
mkdir -p "${GEN}/SharedCacheLinker"
ln -sf "${SRC}/shared_cache_linker/SharedCacheLinker.h" "${GEN}/SharedCacheLinker/SharedCacheLinker.h"
(cd "${SRC}" && DERIVED_FILE_DIR="${GEN}" ARM_SDK="${SDKROOT}" sh build-scripts/generate-cache-config-header.sh)
# PREBUILTLOADER_VERSION hashes the record layouts of dyld's prebuilt-loader
# structures; dyld only uses a cache's prebuilt loaders when its own matches.
# Apple's script, with the public SDK plus Finch's private headers in place of
# macosx.internal.
if [[ ! -s "${GEN}/PrebuiltLoader_version.h" || "${GEN}/PrebuiltLoader_version.h" -ot "$0" ]]; then
    sed -e 's/-sdk macosx.internal clang++/-sdk macosx clang++/' \
        -e "s|-Iinclude/mach-o|-Iinclude/mach-o -include ${FINCH_ROOT}/tools/dsc/prelude.h -I${FINCH_ROOT}/tools/dsc/include -I${SDK}/override -I${SDK}/availability -F${SDK}/Frameworks -I${GEN} -idirafter ${SDK}/include|" \
        "${SRC}/build-scripts/prebuilt-loader-hash.sh" > "${GEN}/prebuilt-loader-hash.sh"
    (cd "${SRC}" && DERIVED_FILE_DIR="${GEN}" DEVELOPER_DIR="$(xcode-select -p)" bash "${GEN}/prebuilt-loader-hash.sh") \
        >> "${LOG}" 2>&1 || { echo "error: PrebuiltLoader_version.h generation failed (see ${LOG})" >&2; exit 1; }
fi
objs=()
pids=()
fail=0
while read -r target src; do
    o="${OBJ}/${target}/${src%.*}.o"
    objs+=("$o")
    [[ "$o" -nt "${SRC}/${src}" && "$o" -nt "$0" ]] && continue
    mkdir -p "$(dirname "$o")"
    case "$src" in
    *.cpp|*.mm) lang=(-std=c++20 -stdlib=libc++) ;;
    *) lang=(-std=c2x) ;;
    esac
    [[ "$src" == *.mm ]] && lang+=(-fobjc-arc)
    ( xcrun clang++ -x "$( [[ $src == *.mm ]] && echo objective-c++ || ([[ $src == *.c ]] && echo c || echo c++))" \
        -c "${common[@]}" $(flags_for "$target") "${lang[@]}" "${incs[@]}" \
        "${SRC}/${src}" -o "$o" >> "${LOG}.${target//\//_}.$(basename "$src").log" 2>&1 \
        || { rm -f "$o"; echo "FAILED ${src}" >> "${LOG}"; } ) &
    pids+=($!)
    if (( ${#pids[@]} >= $(sysctl -n hw.ncpu) )); then wait "${pids[0]}"; pids=("${pids[@]:1}"); fi
done < "${FINCH_ROOT}/tools/dsc/sources.txt"
wait
cat "${LOG}".*.log >> "${LOG}" 2>/dev/null; rm -f "${LOG}".*.log
if grep -q "^FAILED" "${LOG}"; then
    echo "error: $(grep -c '^FAILED' "${LOG}") sources failed (see ${LOG})" >&2
    exit 1
fi

xcrun clang++ -c -arch arm64 -mmacosx-version-min=14.0 -isysroot "${SDKROOT}" -Os -std=c++20 -DINTERNAL_BUILD=1 -DBUILDING_CACHE_BUILDER=1 -DBUILDING_MACHO_WRITER=1 \
    "${incs[@]}" "${FINCH_ROOT}/tools/dsc/finch_missing.cpp" -o "${OBJ}/finch_missing.o"
xcrun clang++ -arch arm64 -mmacosx-version-min=14.0 -isysroot "${SDKROOT}" \
    "${objs[@]}" "${OBJ}/finch_missing.o" \
    -L"${FINCH_ROOT}/build/userland/lib" -lCrashReporterClient \
    -framework Foundation -lc++ -o "${OUT}" >> "${LOG}" 2>&1 \
    || { echo "error: link failed (see ${LOG})" >&2; exit 1; }
echo "built ${OUT}"
