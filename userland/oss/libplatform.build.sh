#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# libsystem_platform.dylib from libplatform. Apple publishes the sources and
# xcodeconfig/*.xcconfig but not the Xcode project, so this follows those
# configs: the arm64 + generic slices of each component, -Os, the same
# preprocessor definitions, os/ built with hidden visibility, and the alias list.
# Called by tools/build-oss.sh (SRC, OBJ, STAGE, SDKROOT, FINCH_*_CFLAGS).
set -euo pipefail

cd "${SRC}"
rm -rf "${OBJ}"
mkdir -p "${OBJ}" "${STAGE}/usr/lib/system"

CC="xcrun -sdk macosx clang"
common=(
    -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os
    -fno-stack-protector -fdollars-in-identifiers -fno-common -momit-leaf-frame-pointer
    -D_FORTIFY_SOURCE=0 -DCONFIG_MTE=1
    -Iprivate -Iinclude -Iinternal -Isrc/os/resolver
    ${FINCH_PRIVATE_CFLAGS} ${FINCH_SDK_CFLAGS}
    -Wno-error -Wno-error=int-conversion -w
)
# Per-component OSAtomic settings (xcodeconfig/{libplatform,os,atomics}.xcconfig).
defs_default=(-DOSATOMIC_USE_INLINED=0 -DOSATOMIC_DEPRECATED=0 -DOSSPINLOCK_USE_INLINED=1 -DOS_UNFAIR_LOCK_INLINE=0)
defs_os=(-DOSATOMIC_USE_INLINED=0 -DOSATOMIC_DEPRECATED=0 -DOSSPINLOCK_USE_INLINED=0 -DOSSPINLOCK_DEPRECATED=0 -fvisibility=hidden)
defs_atomics=(-DOSATOMIC_USE_INLINED=0 -DOSATOMIC_DEPRECATED=0)

objs=()
compile() {   # compile <file> <extra flags...>
    local f="$1" o="${OBJ}/$(echo "$1" | tr '/' '_').o"
    shift
    ${CC} "${common[@]}" "$@" -c "$f" -o "$o"
    objs+=("$o")
}

for f in src/init.c src/force_libplatform_to_build.c; do compile "$f" "${defs_default[@]}"; done
for f in src/os/*.c; do compile "$f" "${defs_os[@]}"; done
for f in src/atomics/init.c src/atomics/arm64/*.c src/atomics/common/*.c; do compile "$f" "${defs_atomics[@]}"; done
for f in src/cachecontrol/arm64/*.s src/cachecontrol/generic/*.c \
         src/setjmp/arm64/*.s src/setjmp/generic/*.c \
         src/simple/*.c src/string/generic/*.c src/timingsafe/arm64/*.c \
         src/ucontext/arm64/*.s src/ucontext/arm64/*.c src/ucontext/generic/*.c; do
    compile "$f" "${defs_default[@]}"
done

# Finch additions for exports Apple's library has but the published source
# lacks (userland/oss/libplatform/). SME routines must not use NEON.
FINCH_SRC="$(cd "$(dirname "$0")" && pwd)/libplatform"
compile "${FINCH_SRC}/finch_bitops.c" "${defs_default[@]}"
compile "${FINCH_SRC}/finch_apt.c" "${defs_default[@]}"
compile "${FINCH_SRC}/finch_sme_string.c" "${defs_default[@]}" -mgeneral-regs-only -fno-builtin

${CC} -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib -nostdlib \
    -install_name /usr/lib/system/libsystem_platform.dylib \
    -compatibility_version 1 -current_version 375.100.10 \
    -umbrella System -L"${SDKROOT}/usr/lib/system" -lsystem_kernel \
    -Wl,-alias_list,xcodeconfig/libplatform.aliases -Wl,-simulator_support \
    "${objs[@]}" -o "${STAGE}/usr/lib/system/libsystem_platform.dylib"
echo "linked libsystem_platform.dylib from ${#objs[@]} objects"
