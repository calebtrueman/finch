#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The Swift half of Foundation.framework. Apple compiles Foundation's Swift
# overlay (module Foundation: Data, URL, Date, the bridging of Array,
# Dictionary, Set and String to NSArray and friends, NSError bridging, the
# NS* extensions) into Foundation.framework itself, so apps import those
# symbols from Foundation. Finch does the same: this script compiles the Swift
# sources into objects that userland/Foundation/build.sh links into the
# Foundation dylib. docs/design/FOUNDATION.md ("The Swift overlay") has the
# design and the symbol parity.
#
# Sources (each pinned; licences in docs/LICENSING.md):
#   swift-foundation        swift-6.3.1-RELEASE (Apache 2.0): FoundationEssentials
#                           and FoundationInternationalization, compiled as Apple
#                           compiles them into Foundation (FOUNDATION_FRAMEWORK).
#   swift-collections       1.1.6 (the Swift 6.3.1 toolchain's pin): Rope,
#                           OrderedCollections, Deque as the private module
#                           CollectionsInternal, linked in statically.
#   Apple's ICU             (userland/projects.txt) headers as _FoundationICU;
#                           Foundation links libicucore.
#   swift/Darwin/           Swift's historical Darwin Foundation overlay
#                           (swift-5.4-RELEASE, Apache 2.0): the parts that
#                           swift-foundation doesn't carry, edited to fit.
#   swift/Finch/            Finch's own Swift for the rest.
#   swift/shims/            the private clang modules the sources import,
#                           declaring what Finch's Foundation and CF provide.
#
#   userland/Foundation/swift/overlay.sh [-typecheck]
#     -> build/obj/Foundation-swift/Foundation-swift.o (+ libCollectionsInternal.a)
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Foundation/swift"
SRC="${FINCH_ROOT}/build/src"
OBJ="${FINCH_ROOT}/build/obj/Foundation-swift"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun -f swiftc)"
TARGET=arm64e-apple-macos26.0
log() { echo "==> $*"; }
mode="${1:-}"

# fetch <repo url> <tag> <dir>
fetch() {
    local url="$1" tag="$2" dir="$3"
    [[ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null || true)" == \
       "$(git -C "${dir}" rev-parse -q --verify "${tag}^{commit}" 2>/dev/null || echo none)" ]] && return
    log "fetching $(basename "${url}" .git) ${tag}"
    rm -rf "${dir}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${tag}" "${url}" "${dir}"
}
SF="${SRC}/swift-foundation"
COLL="${SRC}/swift-collections"
fetch https://github.com/swiftlang/swift-foundation.git swift-6.3.1-RELEASE "${SF}"
fetch https://github.com/apple/swift-collections.git 1.1.6 "${COLL}"
# Finch's patches to swift-foundation (userland/patches/swift-foundation),
# applied idempotently as tools/build-oss.sh applies its projects' patches:
# the few places FOUNDATION_FRAMEWORK code needs Apple-internal pieces Finch
# replaces (field reflection, case folding, Combine, the full
# ComponentsFormatStyle, predicate archiving).
for p in "${FINCH_ROOT}/userland/patches/swift-foundation"/*.patch; do
    [[ -f "$p" ]] || continue
    if git -C "${SF}" apply --check "$p" 2>/dev/null; then
        git -C "${SF}" apply "$p"
    elif ! git -C "${SF}" apply --check --reverse "$p" 2>/dev/null; then
        echo "error: patch does not apply: $p" >&2; exit 1
    fi
done
ICU="${SRC}/ICU/icu/icu4c/source"
[[ -d "${ICU}/common/unicode" ]] || { echo "missing build/src/ICU: run tools/fetch-src.sh ICU" >&2; exit 1; }

mkdir -p "${OBJ}"

# _FoundationICU: ICU's C API, as Apple's ICU installs it (no renaming).
mkdir -p "${OBJ}/icu/unicode"
for d in common i18n io; do ln -sf "${ICU}/${d}/unicode/"*.h "${OBJ}/icu/unicode/"; done
{
    echo '#define U_DISABLE_RENAMING 1'
    echo '#define U_SHOW_INTERNAL_API 1'
    for h in "${OBJ}"/icu/unicode/u*.h; do
        h="$(basename "${h}")"
        case "${h}" in   # C++-only headers
            uniset.h|unistr.h|unifilt.h|unifunct.h|unimatch.h|unirepl.h|uobject.h|ustream.h|\
            usetiter.h|uchriter.h|ucharstrie*.h|ustringtrie.h|utfiterator.h|utfstring.h|\
            urename.h|ulocale.h|ulocbuilder.h) continue ;;
        esac
        echo "#include <unicode/${h}>"
    done
} > "${OBJ}/icu/FoundationICU.h"
printf 'module _FoundationICU [system] {\n    header "FoundationICU.h"\n    export *\n}\n' > "${OBJ}/icu/module.modulemap"

# CollectionsInternal: swift-collections as one module, as Apple's Foundation
# imports it (@_spi(Unstable) internal import CollectionsInternal).
if [[ ! -f "${OBJ}/coll/libCollectionsInternal.a" || "${COLL}" -nt "${OBJ}/coll/libCollectionsInternal.a" ]]; then
    log "CollectionsInternal (swift-collections)"
    mkdir -p "${OBJ}/coll"
    find "${COLL}/Sources/"{DequeModule,OrderedCollections,RopeModule,InternalCollectionsUtilities} \
        -name '*.swift' | sed 's/.*/"&"/' > "${OBJ}/coll/sources.rsp"
    "${SWIFTC}" -emit-library -static -emit-module -module-name CollectionsInternal -parse-as-library -O \
        -target "${TARGET}" -sdk "${SDKROOT}" -swift-version 5 -D COLLECTIONS_SINGLE_MODULE \
        -emit-module-path "${OBJ}/coll/CollectionsInternal.swiftmodule" \
        -o "${OBJ}/coll/libCollectionsInternal.a" @"${OBJ}/coll/sources.rsp" \
        > "${OBJ}/coll/build.log" 2>&1 || { grep -m20 -A3 'error:' "${OBJ}/coll/build.log"; exit 1; }
fi

# The sources: swift-foundation's two modules, minus what Finch leaves out
# (swift/swift-foundation.exclude), plus Finch's Darwin/ and Finch/ files.
{
    find "${SF}/Sources/FoundationEssentials" "${SF}/Sources/FoundationInternationalization" -name '*.swift' \
        | grep -v -F -f <(grep -v '^#' "${HERE}/swift-foundation.exclude" | sed '/^$/d')
    find "${HERE}/Darwin" "${HERE}/Finch" -name '*.swift'
} | sort | sed 's/.*/"&"/' > "${OBJ}/sources.rsp"

AVAIL=()
for v in 0.1 0.2 0.3 0.4 6.0.2 6.1 6.2 6.3; do
    AVAIL+=(-enable-experimental-feature "AvailabilityMacro=FoundationPreview ${v}:macOS 15, iOS 18, tvOS 18, watchOS 11")
done
FLAGS=(-module-name Foundation -import-underlying-module -parse-as-library -enable-library-evolution
    -target "${TARGET}" -sdk "${SDKROOT}" -swift-version 5 -O -enforce-exclusivity=unchecked
    -module-link-name swiftFoundation -autolink-force-load -runtime-compatibility-version none
    -package-name FoundationPreview -D FOUNDATION_FRAMEWORK -D FINCH_FOUNDATION -Xcc -DFOUNDATION_FRAMEWORK=1
    -enable-upcoming-feature InferSendableFromCaptures -enable-upcoming-feature MemberImportVisibility
    -enable-experimental-feature VariadicGenerics -enable-experimental-feature LifetimeDependence
    -enable-experimental-feature AddressableTypes -enable-experimental-feature AllowUnsafeAttribute
    -enable-experimental-feature BuiltinModule -enable-experimental-feature AccessLevelOnImport
    -enable-experimental-feature StrictConcurrency "${AVAIL[@]}"
    -I "${HERE}/shims" -Xcc -I"${HERE}/shims" -I "${OBJ}/icu" -Xcc -I"${OBJ}/icu" -I "${OBJ}/coll"
    -I "${SF}/Sources/_FoundationCShims/include")

if [[ "${mode}" == "-typecheck" ]]; then
    "${SWIFTC}" -typecheck "${FLAGS[@]}" @"${OBJ}/sources.rsp"
    exit
fi
# _FoundationCShims' C half (uuid, string and platform helpers).
mkdir -p "${OBJ}/cshims"
for c in "${SF}/Sources/_FoundationCShims/"*.c; do
    o="${OBJ}/cshims/$(basename "${c%.c}").o"
    [[ "${o}" -nt "${c}" ]] && continue
    "$(xcrun -f clang)" -target "${TARGET}" -isysroot "${SDKROOT}" -Os -DFOUNDATION_FRAMEWORK=1 \
        -I"${SF}/Sources/_FoundationCShims/include" -I"${HERE}/shims" -c "${c}" -o "${o}"
done

# The Swift objects are rebuilt when any input is newer.
if [[ -f "${OBJ}/Foundation-swift.o" ]] && [[ -z "$(find "${HERE}" "${SF}/Sources" "${OBJ}/coll/libCollectionsInternal.a" \
        -newer "${OBJ}/Foundation-swift.o" -type f -print -quit)" ]]; then
    exit 0
fi
log "compiling the Swift overlay"
"${SWIFTC}" -c -wmo "${FLAGS[@]}" @"${OBJ}/sources.rsp" -o "${OBJ}/Foundation-swift.o" \
    > "${OBJ}/build.log" 2>&1 || { grep -m30 -A3 'error:' "${OBJ}/build.log"; exit 1; }
