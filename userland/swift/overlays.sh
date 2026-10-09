#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The Darwin Swift overlays: /usr/lib/swift/libswift<Module>.dylib, the Swift
# half of a C or Objective-C module (ObjectiveC, Dispatch, CoreFoundation,
# os, XPC, IOKit, simd, ...). Swift apps link them (TextEdit imports NSObject's
# == from libswiftObjectiveC, CGFloat from libswiftCoreFoundation, and weakly
# links a dozen more), so Finch builds open ones with Apple's install names,
# versions and symbols. docs/design/FOUNDATION.md ("Swift overlays") has the
# sources and the parity numbers; tools/check-swift-parity.sh measures them.
#
# Sources, each pinned:
#   ObjectiveC   objc4 (userland/projects.txt): Apple's current overlay source.
#   Dispatch     libdispatch (projects.txt): Apple's current overlay source.
#   _Builtin_float  swift-6.3.1-RELEASE (build.sh's checkout), ClangOverlays.
#   CoreFoundation, IOKit, simd, Darwin (+ _DarwinFoundation1-3)
#                Swift's historical Darwin and Platform overlays (Apache 2.0
#                with the Runtime Library Exception; removed from Swift after
#                5.4): swift-5.4-RELEASE and swift-5.2.5-RELEASE, compiled from
#                the checkouts or adapted in userland/swift/overlays/<Module>/.
#   os           Finch's files in overlays/os: the historical os_log and
#                os_signpost (swift-5.2.5) and its C helpers, the logging API
#                adapted from swift-6.3.1's open prototype (stdlib/private/
#                OSLog), Logger/OSSignposter/locks/workgroups written by Finch.
#   XPC, UniformTypeIdentifiers, OSLog, QuartzCore, CoreImage
#                Finch's own code (overlays/<Module>), over Finch's libxpc and
#                frameworks.
# Apple's SDK .swiftinterface files are the specification: the declarations,
# @frozen layouts and @usableFromInline entry points match them.
#
# Each overlay is compiled as Apple's are: resilient (-enable-library-evolution),
# -module-link-name swift<Module> -autolink-force-load, against the SDK's
# clang modules, linking the SDK's Swift libraries (whose install names are
# Finch's too). The runtime libraries come from userland/swift/build.sh.
#
#   userland/swift/overlays.sh   -> build/root/usr/lib/swift/libswift*.dylib
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/swift/overlays"
SRC="${FINCH_ROOT}/build/src"
OBJ="${FINCH_ROOT}/build/obj/swift-overlays"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun -f swiftc)"
CC="$(xcrun -f clang)"
TARGET=arm64e-apple-macos26.0
log() { echo "==> $*"; }

# fetch_swift <tag> <dir>: the Darwin overlays of a historical Swift release.
fetch_swift() {
    local tag="$1" dir="$2"
    [[ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null || true)" == \
       "$(git -C "${dir}" rev-parse -q --verify "${tag}^{commit}" 2>/dev/null || echo none)" ]] && {
        git -C "${dir}" sparse-checkout set stdlib/public/Darwin stdlib/public/SwiftShims stdlib/public/Platform utils
        return; }
    log "fetching ${tag} (stdlib/public/Darwin)"
    rm -rf "${dir}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${tag}" --filter=blob:none --sparse \
        https://github.com/swiftlang/swift.git "${dir}"
    git -C "${dir}" sparse-checkout set stdlib/public/Darwin stdlib/public/SwiftShims stdlib/public/Platform utils
}
OLD52="${SRC}/swift-darwin-overlays-5.2.5"
OLD54="${SRC}/swift-darwin-overlays-5.4"
SWIFT_SRC="${SRC}/swift"   # swift-6.3.1-RELEASE, from userland/swift/build.sh
fetch_swift swift-5.2.5-RELEASE "${OLD52}"
fetch_swift swift-5.4-RELEASE "${OLD54}"
for p in objc4 libdispatch; do
    [[ -d "${SRC}/${p}" ]] || { echo "missing build/src/${p}: run tools/fetch-src.sh ${p}" >&2; exit 1; }
done

# With arguments, only those overlays are rebuilt (the rest stay installed).
ONLY=" $* "
[[ $# -eq 0 ]] && rm -rf "${OBJ}"
rm -rf "${OBJ}/shims" && mkdir -p "${OBJ}/shims/dispatch-private/dispatch"
# Private clang modules: Finch's declarations (shims/), and two of
# libdispatch's private headers as the DispatchPrivate module. Those use
# availability macros only the internal SDK defines, which mean nothing here.
cp "${HERE}/shims/"* "${OBJ}/shims/"
for h in source_private.h swift_concurrency_private.h; do
    { printf '#include <dispatch/dispatch.h>\n#ifndef __DISPATCH_INDIRECT__\n#define __DISPATCH_INDIRECT__\n#endif\n'
      printf '#undef DISPATCH_ENUM_API_AVAILABLE\n#define DISPATCH_ENUM_API_AVAILABLE(...)\n'
      printf '#ifndef SPI_AVAILABLE\n#define SPI_AVAILABLE(...)\n#endif\n'
      sed 's|#include <pthread/private.h>|mach_port_t _pthread_mach_thread_self_direct(void);|' \
          "${SRC}/libdispatch/private/${h}"; } > "${OBJ}/shims/dispatch-private/dispatch/${h}"
done
cat >> "${OBJ}/shims/module.modulemap" <<'EOF'
module DispatchPrivate [system] {
    header "dispatch-private/dispatch/source_private.h"
    header "dispatch-private/dispatch/swift_concurrency_private.h"
    header "dispatch_swift_job.h"
    export *
}
EOF

SWIFTFLAGS=(-target "${TARGET}" -sdk "${SDKROOT}" -O -parse-as-library -enable-library-evolution
    -swift-version 5 -enforce-exclusivity=unchecked -runtime-compatibility-version none
    -autolink-force-load -Xfrontend -experimental-spi-only-imports
    -I "${OBJ}/shims" -Xcc -I"${OBJ}/shims/dispatch-private")
CFLAGS=(-target "${TARGET}" -isysroot "${SDKROOT}" -Os -fno-common -fobjc-arc -I"${OBJ}/shims/dispatch-private")

# overlay <Module> <current-version> <compatibility-version> <swift sources and flags...> [-- <C/ObjC sources>]
# (--no-force-load among the Swift arguments leaves out the force-load symbol)
overlay() {
    local mod="$1" cur="$2" compat="$3"; shift 3
    [[ "${ONLY}" == "  " || "${ONLY}" == *" ${mod} "* ]] || return 0
    local swift=() csrc=() objs=() out="${OBJ}/${mod}" flags=("${SWIFTFLAGS[@]}")
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        if [[ "$1" == "--no-force-load" ]]; then
            local f kept=(); for f in "${flags[@]}"; do [[ "$f" == -autolink-force-load ]] || kept+=("$f"); done
            flags=("${kept[@]}")
        else swift+=("$1"); fi
        shift
    done
    [[ $# -gt 0 ]] && { shift; csrc=("$@"); }
    rm -rf "${out}" && mkdir -p "${out}"
    local c
    for c in "${csrc[@]+"${csrc[@]}"}"; do
        "${CC}" "${CFLAGS[@]}" -c "${c}" \
            -o "${out}/$(basename "${c%.*}").o"
        objs+=("${out}/$(basename "${c%.*}").o")
    done
    log "libswift${mod}"
    "${SWIFTC}" "${flags[@]}" -emit-library -module-name "${mod}" -module-link-name "swift${mod}" \
        "${swift[@]}" "${objs[@]+"${objs[@]}"}" -o "${out}/libswift${mod}.dylib" \
        -Xlinker -install_name -Xlinker "/usr/lib/swift/libswift${mod}.dylib" \
        -Xlinker -current_version -Xlinker "${cur}" -Xlinker -compatibility_version -Xlinker "${compat}" \
        > "${out}/build.log" 2>&1 || { grep -m20 -A3 'error:' "${out}/build.log"; exit 1; }
    # An overlay that imports Swift symbols from Foundation (its Swift half,
    # userland/Foundation/swift) stays out of the root until Finch's
    # Foundation exports them all: the image's dyld shared cache can't
    # hold a library with unresolved imports, weak ones included.
    local missing
    missing=$( { python3 "${FINCH_ROOT}/tools/check-imports.py" --all "${out}/libswift${mod}.dylib" || true; } \
        | awk '/^[^ ]/ { lib = $1 } /^    / && lib == "Foundation:" { n++ } END { print n + 0 }')
    if [[ "${missing}" != 0 ]]; then
        echo "    libswift${mod}: not installed, Finch's Foundation lacks ${missing} of its imports"
        rm -f "${ROOT}/usr/lib/swift/libswift${mod}.dylib"
        return 0
    fi
    install -m 0755 "${out}/libswift${mod}.dylib" "${ROOT}/usr/lib/swift/"
    codesign -f -s - "${ROOT}/usr/lib/swift/libswift${mod}.dylib" 2>/dev/null
}
mkdir -p "${ROOT}/usr/lib/swift"

# --- ObjectiveC (objc4) ------------------------------------------------------
overlay ObjectiveC 951.7 1 "${SRC}/objc4/ObjectiveC/ObjectiveC.swift" -Xcc -DOS_OBJECT_HAVE_OBJC_SUPPORT=0

# --- Dispatch (libdispatch) --------------------------------------------------
# Apple's also conforms DispatchQueue to Combine's Scheduler
# (Schedulers+DispatchQueue.swift, weak-linking Combine); Finch has no
# Combine, so that file is left out.
D="${SRC}/libdispatch/src/swift"
overlay Dispatch 1542.100.32 1 "${D}"/{Block,Data,Dispatch,IO,Private,Queue,Source,Time}.swift \
    -I "${D}/shims" -- "${D}/Dispatch.mm"

# --- _Builtin_float (Swift 6.3.1's ClangOverlays, as Runtimes/Overlay builds it)
gyb() {   # gyb <in> <out>: expand a .gyb template with Swift's gyb
    python3 "${SWIFT_SRC}/utils/gyb.py" -DCMAKE_SIZEOF_VOID_P=8 --line-directive= -o "$2" "$1"
}
mkdir -p "${OBJ}/gyb"
gyb "${SWIFT_SRC}/stdlib/public/ClangOverlays/float.swift.gyb" "${OBJ}/gyb/float.swift"
overlay _Builtin_float 0 0 "${OBJ}/gyb/float.swift" -Xfrontend -module-abi-name -Xfrontend Darwin

# --- CoreFoundation: _CFObject (swift-5.4) and CGFloat (Finch's, from swift-5.4)
overlay CoreFoundation 120.100 1 "${OLD54}/stdlib/public/Darwin/CoreFoundation/CoreFoundation.swift" \
    "${HERE}/CoreFoundation/CGFloat.swift" -framework CoreFoundation -- "${HERE}/CoreFoundation/CoreFoundationOverlay.c"

# --- IOKit (swift-5.2.5) -----------------------------------------------------
overlay IOKit 1 1 "${OLD52}/stdlib/public/Darwin/IOKit/IOReturn.swift" -framework IOKit

# --- os: the historical os_log/os_signpost overlay (swift-5.2.5) and the
# newer logging API (Logger, OSLogMessage, OSSignposter, ...): Finch's files
# in overlays/os, partly adapted from Swift 6.3.1's open prototype
# (stdlib/private/OSLog). The C helpers encode os_log's arguments for
# libsystem_trace's pack API (declared by the SDK's _SwiftOSOverlayShims
# module, which the SDK still ships for the obsolete overlay); format.m reads %s strings as NSString without
# linking Foundation (os_nsstring.h).
OSC="${OBJ}/os-c"; mkdir -p "${OSC}"
O52="${OLD52}/stdlib/public/Darwin/os"
cp "${O52}"/{format.h,os_trace_blob.h,os_trace_blob.c,thunks.h} "${HERE}/os/os_nsstring.h" "${OSC}/"
sed -e '/#include <CoreFoundation\/CoreFoundation.h>/d' -e 's|#include <Foundation/Foundation.h>|#include <errno.h>|' \
    "${O52}/os.m" > "${OSC}/os.m"
sed 's|#include <Foundation/Foundation.h>|#include "os_nsstring.h"|' "${O52}/format.m" > "${OSC}/format.m"
overlay os 1082 1 "${HERE}"/os/*.swift \
    -- "${OSC}"/{os.m,format.m,os_trace_blob.c} "${HERE}/os/os_thunks.c"

# UniformTypeIdentifiers and OSLog use the Foundation overlay's types (URL,
# Data, String bridging), which Apple compiles into Foundation.framework.
# They link Foundation weakly, and overlay() leaves them out of build/root
# while Finch's Foundation lacks any of those symbols.
WEAK_FOUNDATION=(-Xlinker -weak_framework -Xlinker Foundation)

# --- UniformTypeIdentifiers: Finch's UTType over Finch's framework ----------
overlay UniformTypeIdentifiers 877.4.9 1 "${HERE}"/UniformTypeIdentifiers/*.swift \
    -framework UniformTypeIdentifiers "${WEAK_FOUNDATION[@]}"

# --- simd: swift-5.2.5's gyb sources, and Finch's additions (overlays/simd) ---
for f in simd Quaternion; do
    gyb "${OLD52}/stdlib/public/Darwin/simd/${f}.swift.gyb" "${OBJ}/gyb/${f}.swift"
done
sed -i '' 's/^  var _descriptionAsArray/  @inlinable var _descriptionAsArray/' "${OBJ}/gyb/simd.swift"
python3 "${HERE}/simd/gen-simd-math.py" > "${OBJ}/gyb/SIMDMath.swift"
overlay simd 23 1 "${OBJ}"/gyb/{simd,Quaternion,SIMDMath}.swift "${HERE}/simd/SIMDExtras.swift"

# --- OSLog, QuartzCore, CoreImage: Finch's (overlays/<Module>) -----------------
overlay OSLog 10 1 "${HERE}/OSLog/OSLog.swift" "${WEAK_FOUNDATION[@]}"
overlay QuartzCore 5 1 "${HERE}/QuartzCore/QuartzCore.swift" -framework QuartzCore -framework Foundation \
    -Xfrontend -disable-autolink-library -Xfrontend swiftMetal  # Finch has no Metal
overlay CoreImage 2.2 1 "${HERE}/CoreImage/CoreImage.swift"

# --- Darwin: libswiftDarwin and the _DarwinFoundation1-3 libraries it
# re-exports (Apple's SDK splits the C library into those clang modules),
# all with Darwin's ABI name; plus the one-symbol libraries that stand for
# each C submodule (libswift_errno, ...) and re-export the right one.
# Sources: overlays/Darwin (from swift-5.4's Platform overlay) and swift-5.4's
# tgmath.swift.gyb, MachError.swift, TiocConstants.swift. Like Apple's, the
# _DarwinFoundation libraries have no force-load symbol.
P54="${OLD54}/stdlib/public/Platform"
gyb "${P54}/tgmath.swift.gyb" "${OBJ}/gyb/tgmath.swift"
ABI_DARWIN=(-Xfrontend -module-abi-name -Xfrontend Darwin)
overlay _DarwinFoundation1 377.100.15 1 "${HERE}/Darwin/DarwinFoundation1.swift" "${OBJ}/gyb/tgmath.swift" \
    "${HERE}/Darwin/POSIXError.swift" "${ABI_DARWIN[@]}" --no-force-load
overlay _DarwinFoundation2 377.100.15 1 "${HERE}/Darwin/DarwinFoundation2.swift" "${ABI_DARWIN[@]}" --no-force-load
overlay _DarwinFoundation3 377.100.15 1 "${HERE}/Darwin/DarwinFoundation3.swift" "${ABI_DARWIN[@]}" --no-force-load
L="${ROOT}/usr/lib/swift"
overlay Darwin 377.100.15 1 "${HERE}/Darwin/Darwin.swift" "${P54}/MachError.swift" "${P54}/TiocConstants.swift" \
    -Xcc -DSWIFT_STDLIB_HAS_ENVIRON \
    -Xlinker -reexport_library -Xlinker "${L}/libswift_Builtin_float.dylib" \
    -Xlinker -reexport_library -Xlinker "${L}/libswift_DarwinFoundation1.dylib" \
    -Xlinker -reexport_library -Xlinker "${L}/libswift_DarwinFoundation2.dylib" \
    -Xlinker -reexport_library -Xlinker "${L}/libswift_DarwinFoundation3.dylib"
# shim <name> <DarwinFoundation N>: libswift<name>.dylib, its force-load
# symbol, re-exporting libswift_DarwinFoundation<N>.
shim() {
    [[ "${ONLY}" == "  " || "${ONLY}" == *" $1 "* ]] || return 0
    local out="${OBJ}/$1"; rm -rf "${out}" && mkdir -p "${out}"
    printf '__attribute__((visibility("default"))) char swift_force_load __asm("__swift_FORCE_LOAD_$_swift%s") = 0;\n' "$1" \
        > "${out}/force-load.c"
    log "libswift$1"
    "${CC}" -target "${TARGET}" -isysroot "${SDKROOT}" -dynamiclib "${out}/force-load.c" -o "${out}/libswift$1.dylib" \
        -install_name "/usr/lib/swift/libswift$1.dylib" -current_version 0 -compatibility_version 0 \
        -Wl,-reexport_library,"${L}/libswift_DarwinFoundation$2.dylib"
    install -m 0755 "${out}/libswift$1.dylib" "${L}/"
    codesign -f -s - "${L}/libswift$1.dylib" 2>/dev/null
}
shim _errno 1; shim _math 1; shim _stdio 2; shim _time 2; shim sys_time 2; shim _signal 3; shim unistd 3

# --- XPC: Finch's (overlays/XPC) over Finch's libxpc ---------------------------
overlay XPC 128.100.15 1 "${HERE}"/XPC/*.swift

log "installed build/root/usr/lib/swift: $(cd "${ROOT}/usr/lib/swift" && ls libswift*.dylib | wc -l | tr -d ' ') libraries"
for version in 5.2.5 5.4; do
    notice="${ROOT}/usr/share/finch/licenses/swift-darwin-overlays-${version}"
    mkdir -p "${notice}"
    cp "${SRC}/swift-darwin-overlays-${version}/LICENSE.txt" "${notice}/"
done
# The current ObjectiveC and Dispatch overlays come from separate projects.
# Keep both project licences and the notices in the sources we compile.
notice="${ROOT}/usr/share/finch/licenses/objc4-swift-overlay"
mkdir -p "${notice}"
cp "${SRC}/objc4/APPLE_LICENSE" "${notice}/"
python3 "${FINCH_ROOT}/tools/collect-notices.py" \
    'Apple objc4-951.7 ObjectiveC Swift overlay' "${notice}/SOURCE-NOTICES.txt" \
    "${SRC}/objc4/ObjectiveC/ObjectiveC.swift"
notice="${ROOT}/usr/share/finch/licenses/libdispatch-swift-overlay"
mkdir -p "${notice}"
cp "${SRC}/libdispatch/LICENSE" "${notice}/"
# Dispatch's Swift files name Swift's Runtime Library Exception as well.
cp "${SWIFT_SRC}/LICENSE.txt" "${notice}/SWIFT-LICENSE.txt"
python3 "${FINCH_ROOT}/tools/collect-notices.py" \
    'Apple libdispatch-1542.100.32 Dispatch Swift overlay' "${notice}/SOURCE-NOTICES.txt" \
    "${D}"/{Block,Data,Dispatch,IO,Private,Queue,Source,Time}.swift "${D}/Dispatch.mm"
