#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# IOKit.framework from Apple's IOKitUser (pinned in userland/projects.txt),
# built by Finch (docs/design/COREFOUNDATION.md, "What's needed").
#
# IOKitUser's Xcode project expects Apple's internal SDK, whose IOKit and
# SystemConfiguration private headers aren't public, and builds subprojects
# for hardware Finch doesn't drive yet (HID event system, graphics, display
# ports, USB). This builds the parts Finch's binaries need, from IOKitUser's
# own sources: IOKitLib (registry, services, notifications, user clients),
# the CF serializers, power management (pwr_mgt) and power sources (ps). The
# rest is added as something imports it (tools/check-closed.py).
#
# Headers come from open sources only:
#   <IOKit/...>      the SDK's public IOKit headers, IOKitUser's own (mapped into
#                    the framework layout), and xnu's IOKit private headers
#   <SystemConfiguration/...>  the SDK's public headers and configd's private ones
#   userland/IOKit/include     Finch's: <CoreFoundation/CFXPCBridge.h>, <energytrace.h>
#
# Linked as Apple ships it: install name, current version 275.
#
#   userland/IOKit/build.sh  -> build/root/System/Library/Frameworks/IOKit.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/IOKit"
SRC="${FINCH_ROOT}/build/src/IOKitUser"
CONFIGD="${FINCH_ROOT}/build/src/configd"
XNU="${FINCH_ROOT}/build/xnu-work"
OBJ="${FINCH_ROOT}/build/obj/IOKit"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/IOKit.framework"
SDK="${FINCH_ROOT}/build/sdk"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
MIG="$(xcrun -f mig)"
log() { echo "==> $*"; }

[[ -d "${SRC}" ]] || { echo "missing IOKitUser (tools/fetch-src.sh IOKitUser)" >&2; exit 1; }
[[ -d "${CONFIGD}" ]] || { echo "missing configd (tools/fetch-src.sh configd)" >&2; exit 1; }
[[ -f "${ROOT}/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" ]] \
    || { echo "build CoreFoundation first (userland/CoreFoundation/build.sh)" >&2; exit 1; }

# Finch fixes to IOKitUser (applied once; see each patch).
for p in "${HERE}"/patches/*.patch; do
    [[ -e "$p" ]] || continue
    git -C "${SRC}" apply -R --check "$p" 2>/dev/null || { log "applying $(basename "$p")"; git -C "${SRC}" apply "$p"; }
done

log "assembling headers"
H="${OBJ}/hdr"
rm -rf "${H}" && mkdir -p "${H}/IOKit" "${H}/SystemConfiguration" "${OBJ}/gen"
rsync -a "${SDKROOT}/System/Library/Frameworks/IOKit.framework/Headers/" "${H}/IOKit/"
# IOKitUser's headers, into the framework layout (<IOKit/pwr_mgt/IOPMLib.h>, ...).
cp "${SRC}"/*.h "${H}/IOKit/"
for sub in pwr_mgt ps platform kext; do
    mkdir -p "${H}/IOKit/${sub}"
    cp "${SRC}/${sub}.subproj/"*.h "${H}/IOKit/${sub}/" 2>/dev/null || true
done
# xnu's IOKit private headers fill in the rest (IOPMPrivate.h, IOKitKeysPrivate.h, ...).
rsync -a --ignore-existing "${XNU}/fakeroot/System/Library/Frameworks/IOKit.framework/Versions/A/PrivateHeaders/" "${H}/IOKit/"
rsync -a "${SDKROOT}/System/Library/Frameworks/SystemConfiguration.framework/Headers/" "${H}/SystemConfiguration/"
# configd's SystemConfiguration headers fill in the private ones (SCPrivate.h, SCValidation.h, ...).
rsync -a --ignore-existing --include='*.h' --exclude='*' "${CONFIGD}/SystemConfiguration.fproj/" "${H}/SystemConfiguration/"
rsync -a "${HERE}/include/" "${H}/"
# CF's private <CoreFoundation/CFRuntime.h>, from the source Finch's CoreFoundation
# is built from, with its includes pointed at the framework.
CFINC="${FINCH_ROOT}/build/src/swift-corelibs-foundation/Sources/CoreFoundation/include"
[[ -f "${CFINC}/CFRuntime.h" ]] || { echo "build CoreFoundation first (userland/CoreFoundation/build.sh)" >&2; exit 1; }
for h in CFRuntime.h CFPriv.h CFBundlePriv.h; do
    sed -E 's|#include "(CF[A-Za-z]+\.h)"|#include <CoreFoundation/\1>|' "${CFINC}/${h}" > "${H}/CoreFoundation/${h}"
done
# App Nap SPI Apple's CFPriv.h declares and Finch's CoreFoundation implements
# (CFPlatform_Finch.c); swift-corelibs' CFPriv.h doesn't have it.
cat >> "${H}/CoreFoundation/CFPriv.h" <<'EOH'

/* Finch (userland/CoreFoundation/CFPlatform_Finch.c) */
typedef CF_OPTIONS(uint64_t, __CFRunLoopOptions) {
    __CFRunLoopOptionsTakeAssertion = 1 << 0,
    __CFRunLoopOptionsDropAssertion = 1 << 1,
};
CF_EXPORT void __CFRunLoopSetOptionsReason(__CFRunLoopOptions options, CFStringRef reason);
EOH

log "generating MIG interfaces"
"${MIG}" -arch arm64e -novouchers -DIOKIT -DKOBJECT_SERVER -server /dev/null \
    -header "${OBJ}/gen/iokitmig64.h" -user "${OBJ}/gen/iokitmig64.c" \
    -I"${XNU}/fakeroot/usr/include" -isysroot "${SDKROOT}" "${XNU}/xnu/osfmk/device/device.defs"
cp "${OBJ}/gen/iokitmig64.h" "${H}/IOKit/iokitmig_c.h"   # <IOKit/iokitmig.h> wraps it
"${MIG}" -arch arm64e -server /dev/null -header "${OBJ}/gen/powermanagement.h" \
    -user "${OBJ}/gen/powermanagementUser.c" -isysroot "${SDKROOT}" "${SRC}/pwr_mgt.subproj/powermanagement.defs"

srcs=(
    IOKitLib.c iokitmig.c IOCFSerialize.c IOCFUnserialize.tab.c IOCFPlugIn.c IOCFURLAccess.c
    IODataQueueClient.c IOCircularDataQueue.c IOMIGMachPort.c IOSystemConfiguration.c
)
srcs=("${srcs[@]/#/${SRC}/}")
srcs+=("${SRC}"/pwr_mgt.subproj/*.c "${SRC}"/ps.subproj/*.c "${SRC}"/platform.subproj/*.c "${OBJ}/gen/powermanagementUser.c" "${SRC}/IOTrap.s")

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fblocks
    -I"${H}" -I"${OBJ}/gen" -I"${SRC}" -I"${SRC}/pwr_mgt.subproj" -I"${SRC}/ps.subproj"
    -F"${SDK}/Frameworks"
    # Private headers first, as in Apple's internal SDK: xnu's <mach/message.h>
    # declares mach_msg2(), which the generated kernel-interface stubs call.
    -I"${SDK}/include" -idirafter "${SDK}/override" -idirafter "${SDK}/availability"
    -I"${FINCH_ROOT}/userland/corecrypto/compat"   # <corecrypto/ccmode.h> (IOHibernatePrivate.h)
    -DIOKIT_SERVER_VERSION=20150101 -D__APPLE_API_PRIVATE -DPRIVATE
    -D__ASSERT_MACROS_DEFINE_VERSIONS_WITHOUT_UNDERSCORES=1
    -Wno-deprecated-declarations
    -Wno-error=int-conversion)   # Apple's pwr_mgt code mixes pointers and uintptr_t handles (same width)

log "compiling"
mkdir -p "${OBJ}/o"
failed=0
for s in "${srcs[@]}"; do
    o="${OBJ}/o/$(basename "${s%.*}").o"
    extra=()
    # IOPMEnergyPrefs.c messages powerd with keys no published header defines.
    [[ "$(basename "$s")" == IOPMEnergyPrefs.c ]] && extra=(-include "${HERE}/include/IOPMEnergyPrefs_Finch.h")
    "${CC}" "${CFLAGS[@]}" ${extra[@]+"${extra[@]}"} -c "$s" -o "$o" 2> "$o.log" \
        || { echo "  failed: $(basename "$s") ($(grep -c 'error:' "$o.log") errors, ${o#"${FINCH_ROOT}/"}.log)"; failed=1; }
done
[[ ${failed} == 0 ]] || { echo "compile failed" >&2; exit 1; }

log "linking"
mkdir -p "${FW}/Versions/A"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/IOKit.framework/Versions/A/IOKit \
    -current_version 275 -compatibility_version 1 \
    "${OBJ}"/o/*.o -o "${FW}/Versions/A/IOKit" \
    -F"${ROOT}/System/Library/Frameworks" -framework CoreFoundation -lbsm -lSystem
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/IOKit "${FW}/IOKit"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A IOKit com.apple.framework.IOKit "I/O Kit Framework" 2.0.2 "" English
codesign -f -s - -i com.apple.framework.IOKit "${FW}/Versions/A/IOKit" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
