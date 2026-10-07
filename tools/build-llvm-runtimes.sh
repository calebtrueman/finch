#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build libc++, libc++abi and libunwind from upstream LLVM (Apple ships them
# from its own LLVM fork, which isn't published) and link them as Apple ships
# them: same install names, versions, dependencies and exports
# (userland/llvm/exports/*.exp, Apple's export lists). Apple-specific
# additions are Finch code in userland/llvm. Installs into build/root.
#
#   tools/build-llvm-runtimes.sh
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LLVM_TAG=llvmorg-22.1.8          # first release with arm64e (ptrauth) unwinding
SRC="${FINCH_ROOT}/build/src/llvm-project"
OBJ="${FINCH_ROOT}/build/obj/llvm-runtimes"
ROOT="${FINCH_ROOT}/build/root"
HERE="${FINCH_ROOT}/userland/llvm"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"; CXX="$(xcrun -f clang++)"
log() { echo "==> $*"; }

if [[ "$(git -C "${SRC}" describe --tags --exact-match 2>/dev/null || true)" != "${LLVM_TAG}" ]]; then
    log "fetching ${LLVM_TAG} (runtimes only)"
    rm -rf "${SRC}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${LLVM_TAG}" --filter=blob:none --sparse \
        https://github.com/llvm/llvm-project.git "${SRC}"
    git -C "${SRC}" sparse-checkout set libcxx libcxxabi libunwind runtimes cmake llvm/cmake \
        llvm/utils/llvm-lit llvm/utils/lit third-party/benchmark libc/shared libc/src/__support \
        libc/hdr libc/include/llvm-libc-macros libc/include/llvm-libc-types
fi
# Finch patches (keep Apple's exported ABI where upstream has narrowed it).
for p in "${HERE}"/patches/*.patch; do
    git -C "${SRC}" apply -R --check "$p" 2>/dev/null || { log "applying $(basename "$p")"; git -C "${SRC}" apply "$p"; }
done

log "compiling (upstream Apple configuration)"
cmake -G Ninja -S "${SRC}/runtimes" -B "${OBJ}" -C "${SRC}/libcxx/cmake/caches/Apple.cmake" \
    -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
    -DCMAKE_OSX_ARCHITECTURES=arm64e -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DCMAKE_OSX_SYSROOT="${SDKROOT}" \
    -DCMAKE_C_COMPILER="${CC}" -DCMAKE_CXX_COMPILER="${CXX}" \
    -DLIBCXX_INCLUDE_TESTS=OFF -DLIBCXXABI_INCLUDE_TESTS=OFF -DLIBUNWIND_INCLUDE_TESTS=OFF \
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF > "${FINCH_ROOT}/build/logs/llvm-runtimes-cmake.log"
ninja -C "${OBJ}" cxx_shared cxxabi_shared unwind_shared > "${FINCH_ROOT}/build/logs/llvm-runtimes.log"

objs() { find "${OBJ}/$1" -name '*.o' | sort; }
common=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os)
out="${OBJ}/finch"; mkdir -p "${out}"

log "Finch additions"
"${CXX}" "${common[@]}" -std=c++20 -c "${HERE}/typed_new_delete.cpp" -o "${out}/typed_new_delete.o"
"${CXX}" "${common[@]}" -std=c++20 -c "${HERE}/hardening.cpp" -o "${out}/hardening.o"
"${CXX}" "${common[@]}" -std=c++20 -c "${HERE}/numpunct_compat.cpp" -o "${out}/numpunct_compat.o"
# Apple's $ld$previous$ annotations (symbols that moved from libc++abi), as
# one-byte constants, as Apple emits them.
{
    echo '.section __TEXT,__const'
    grep '^\$ld\$' "${HERE}/exports/libc++.exp" | while read -r s; do
        printf '.globl "%s"\n"%s":\n  .byte 0\n' "$s" "$s"
    done
} > "${out}/ld-previous.s"
"${CC}" -arch arm64e -c "${out}/ld-previous.s" -o "${out}/ld-previous.o"

log "linking libunwind (libSystem sub-library)"
"${CC}" "${common[@]}" -dynamiclib -nostdlib -o "${out}/libunwind.dylib" \
    -install_name /usr/lib/system/libunwind.dylib -compatibility_version 1 -current_version 2100.2 \
    -Wl,-umbrella,System -Wl,-exported_symbols_list,"${HERE}/exports/libunwind.exp" \
    $(objs libunwind/src/CMakeFiles/unwind_shared_objects.dir) \
    -L"${SDKROOT}/usr/lib/system" -lsystem_malloc -lsystem_c -ldyld -Wl,-upward-lcompiler_rt \
    -lsystem_pthread -lsystem_platform

log "linking libc++abi"
"${CXX}" "${common[@]}" -dynamiclib -nostdlib++ -o "${out}/libc++abi.dylib" \
    -install_name /usr/lib/libc++abi.dylib -compatibility_version 1 -current_version 2100.43 \
    -Wl,-exported_symbols_list,"${HERE}/exports/libc++abi.exp" \
    $(objs libcxxabi/src/CMakeFiles/cxxabi_shared_objects.dir) "${out}/typed_new_delete.o" -lSystem

log "linking libc++"
"${CXX}" "${common[@]}" -dynamiclib -nostdlib++ -o "${out}/libc++.1.dylib" \
    -install_name /usr/lib/libc++.1.dylib -compatibility_version 1 -current_version 2100.43 \
    -Wl,-exported_symbols_list,"${HERE}/exports/libc++.exp" \
    -Wl,-force_symbols_not_weak_list,"${SRC}/libcxx/lib/notweak.exp" \
    -Wl,-force_symbols_weak_list,"${SRC}/libcxx/lib/weak.exp" \
    $(objs libcxx/src/CMakeFiles/cxx_shared.dir) "${out}/hardening.o" "${out}/numpunct_compat.o" "${out}/ld-previous.o" \
    "${out}/libc++abi.dylib" \
    -Wl,-reexported_symbols_list,"${HERE}/exports/libc++.reexports" \
    -lSystem

log "installing into build/root"
mkdir -p "${ROOT}/usr/lib/system"
install -m 755 "${out}/libunwind.dylib" "${ROOT}/usr/lib/system/libunwind.dylib"
install -m 755 "${out}/libc++abi.dylib" "${ROOT}/usr/lib/libc++abi.dylib"
install -m 755 "${out}/libc++.1.dylib" "${ROOT}/usr/lib/libc++.1.dylib"
ln -sf libc++.1.dylib "${ROOT}/usr/lib/libc++.dylib"
for f in "${ROOT}/usr/lib/system/libunwind.dylib" "${ROOT}/usr/lib/libc++abi.dylib" "${ROOT}/usr/lib/libc++.1.dylib"; do
    codesign -f -s - "$f" 2>/dev/null
done
log "done"
