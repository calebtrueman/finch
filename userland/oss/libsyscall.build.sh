#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# libsystem_kernel.dylib from xnu's libsyscall, built from the same patched xnu
# tree as the Finch kernel (build/xnu-work/xnu; tools/build-kernel.sh makes it).
# build/src/libsyscall is a symlink into that tree. Called by tools/build-oss.sh.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAKEROOT="${FINCH_ROOT}/build/xnu-work/fakeroot"   # mig, xnu headers from the kernel build

# libsyscall is the system's own syscall layer: xnu's private headers (supersets
# of the public SDK's, e.g. mach/message.h with mach_msg2) must win over the SDK.
PRIVATE_FIRST="-I${FINCH_ROOT}/build/sdk/availability -I${FAKEROOT}/System/Library/Frameworks/System.framework/Versions/B/PrivateHeaders -I${FAKEROOT}/usr/local/include"

# os/x18.c needs <arm64/machine_machdep.h> from Kernel.framework. Expose only
# that header: the whole Kernel.framework include dir would shadow the
# compiler's <stdatomic.h> (via #include_next) with the kernel's.
mkdir -p "${OBJ}/kernel-hdrs/arm64"
chmod -R u+w "${OBJ}/kernel-hdrs"
cp -f "${FAKEROOT}/System/Library/Frameworks/Kernel.framework/Versions/A/Headers/arm64/machine_machdep.h" \
    "${OBJ}/kernel-hdrs/arm64/"

# Libsyscall.xcconfig's MIG include paths assume Apple's internal SDK; point
# them at xnu's installed headers instead.
cd "${SRC}"
env LD="$(xcrun -find clang)" LDPLUSPLUS="$(xcrun -find clang++)" \
xcodebuild install -target Libsyscall_dynamic -sdk macosx \
    ARCHS=arm64e VALID_ARCHS="arm64 arm64e" ONLY_ACTIVE_ARCH=NO \
    TARGET_CONFIGS="DEVELOPMENT ARM64 T8132" \
    RC_ProjectSourceVersion=12377.101.15 CURRENT_PROJECT_VERSION=12377.101.15 VERSIONING_SYSTEM='$(FINCH_VERSIONING_$(TARGET_NAME))' FINCH_VERSIONING_Libsyscall_static=apple-generic VERSION_INFO_PREFIX=___ \
    OBJROOT="${OBJ}" SYMROOT="${OBJ}/sym" DSTROOT="${STAGE}" \
    FAKEROOT_DIR="${FAKEROOT}" \
    OTHER_MIGFLAGS="-novouchers -I${FAKEROOT}/System/Library/Frameworks/System.framework/Versions/B/PrivateHeaders -I${FAKEROOT}/usr/local/include -I${FAKEROOT}/usr/include -I${SDKROOT}/usr/include -DKOBJECT_SERVER" \
    CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    OTHER_CFLAGS='$(inherited) -Wno-error '"${PRIVATE_FIRST} ${FINCH_SDK_CFLAGS} -idirafter ${OBJ}/kernel-hdrs"
