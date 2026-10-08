#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreFoundation.framework: Finch's CoreFoundation (docs/design/COREFOUNDATION.md).
# The source is Apple's CF as published in swift-corelibs-foundation (Apache
# 2.0, pinned below), built for the Objective-C runtime as Apple builds it
# (DEPLOYMENT_RUNTIME_SWIFT=0, Apple's CF runtime ABI for CFSTR), against
# Finch's libicucore (ICU, tools/build-oss.sh ICU). Finch's fixes are the
# patch series in patches/ and finch_prefix.h; Finch's additions are the .c
# and .m files in this directory.
#
# Linked as Apple ships it: install name, current version 4424.1.255,
# compatibility version 150, re-exporting libobjc, with __CFInitialize as the
# library's initializer (swift-corelibs makes it a constructor only off Darwin).
#
#   userland/CoreFoundation/build.sh
#     -> build/root/System/Library/Frameworks/CoreFoundation.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreFoundation"
TAG=swift-6.4.0-RELEASE
SRC="${FINCH_ROOT}/build/src/swift-corelibs-foundation"
# The Darwin-only run-loop sources, which swift-corelibs dropped from its
# tree in 2024: the same project and license, from its last release with them.
DARWIN_TAG=swift-5.10.1-RELEASE
DARWIN_FILES=(
    "CFMachPort.c d05124ae4b29dd55a7518bac2980ce442fda84156133c0fa99b94b0b80bb04e9"
    "CFMachPort_Lifetime.c 27367ad63cb523d3333b23eced1ca6811bf2aa8ccb9032ad8a0f1ff876fee0d3"
    "CFMessagePort.c 4f65c6088cc743441fab855fead2e1c0e67135cb62705917d7a7ed5be7ba7b37"
)
DARWIN="${FINCH_ROOT}/build/src/swift-corelibs-foundation-darwin"
CF="${SRC}/Sources/CoreFoundation"
ICU="${FINCH_ROOT}/build/src/ICU/icu/icu4c/source"
OBJ="${FINCH_ROOT}/build/obj/CoreFoundation"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/CoreFoundation.framework"
SDK="${FINCH_ROOT}/build/sdk"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

[[ -f "${ROOT}/usr/lib/libicucore.A.dylib" ]] || { echo "build libicucore first: tools/build-oss.sh ICU" >&2; exit 1; }

# (Compared by commit: several snapshot tags name the release's commit.)
if [[ "$(git -C "${SRC}" rev-parse HEAD 2>/dev/null || true)" != \
      "$(git -C "${SRC}" rev-parse -q --verify "${TAG}^{commit}" 2>/dev/null || echo none)" ]]; then
    log "fetching swift-corelibs-foundation ${TAG} (CoreFoundation only)"
    rm -rf "${SRC}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${TAG}" --filter=blob:none --sparse \
        https://github.com/swiftlang/swift-corelibs-foundation.git "${SRC}"
    git -C "${SRC}" sparse-checkout set Sources/CoreFoundation
fi
for p in "${HERE}"/patches/*.patch; do
    [[ -e "$p" ]] || continue
    git -C "${SRC}" apply -R --check "$p" 2>/dev/null || { log "applying $(basename "$p")"; git -C "${SRC}" apply "$p"; }
done

mkdir -p "${DARWIN}"
for entry in "${DARWIN_FILES[@]}"; do
    read -r f sum <<<"${entry}"
    if [[ "$(shasum -a 256 "${DARWIN}/${f}" 2>/dev/null | cut -c1-64)" != "${sum}" ]]; then
        log "fetching ${f} (${DARWIN_TAG})"
        curl -sfL -o "${DARWIN}/${f}" \
            "https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/${DARWIN_TAG}/CoreFoundation/RunLoop.subproj/${f}"
        [[ "$(shasum -a 256 "${DARWIN}/${f}" | cut -c1-64)" == "${sum}" ]] || { echo "${f}: checksum mismatch" >&2; exit 1; }
    fi
done

# Headers by framework path (<CoreFoundation/CFBase.h>, as the Darwin files
# include them) are swift-corelibs' own, ahead of the SDK's; <bootstrap.h> is
# Apple-internal shorthand for <servers/bootstrap.h>.
mkdir -p "${OBJ}/hdr"
ln -sfn "${CF}/include" "${OBJ}/hdr/CoreFoundation"
echo '#include <servers/bootstrap.h>' > "${OBJ}/hdr/bootstrap.h"

# swift-corelibs includes ICU as <_foundation_unicode/...> (its renamed ICU
# package); here that's Apple's ICU, whose libicucore exports unversioned
# names (U_DISABLE_RENAMING).
mkdir -p "${OBJ}/icu/_foundation_unicode"
for h in "${ICU}"/{common,i18n,io}/unicode/*.h; do
    ln -sfn "$h" "${OBJ}/icu/_foundation_unicode/$(basename "$h")"
done

# Sources: swift-corelibs' list (its CMakeLists), less its libuuid for other
# platforms (Darwin's is in libSystem), plus Finch's.
srcs=$(sed -n '/add_library(CoreFoundation STATIC/,/)/p' "${CF}/CMakeLists.txt" | grep -o '[A-Za-z_]*\.c' \
    | grep -vx 'uuid\.c' | sed "s|^|${CF}/|")
srcs+=" $(for e in "${DARWIN_FILES[@]}"; do echo "${DARWIN}/${e%% *}"; done)"
srcs+=" $(ls "${HERE}"/*.c "${HERE}"/*.m "${HERE}"/*.s 2>/dev/null || true)"

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g
    -DCF_BUILDING_CF -DDEPLOYMENT_RUNTIME_SWIFT=0 -DINCLUDE_OBJC=1 -DHAVE_STRUCT_TIMESPEC -DU_DISABLE_RENAMING=1
    -I"${OBJ}/hdr" -I"${CF}/include" -I"${CF}/internalInclude" -I"${HERE}" -fno-objc-arc
    -include "${CF}/internalInclude/CoreFoundation_Prefix.h" -include "${HERE}/finch_prefix.h"
    -I"${OBJ}/icu" -I"${ICU}/common" -I"${ICU}/i18n" -I"${ICU}/io"
    -idirafter "${SDK}/override" -idirafter "${SDK}/include" -idirafter "${SDK}/availability"
    -fconstant-cfstrings -fblocks -fdollars-in-identifiers -fno-common -fexceptions
    -Wno-shorten-64-to-32 -Wno-deprecated-declarations -Wno-unreachable-code
    -Wno-conditional-uninitialized -Wno-unused-variable -Wno-unused-function
    -Wno-int-conversion -Wno-switch -Wno-nullability-completeness)

log "compiling"
mkdir -p "${OBJ}/o"
failed=0
compile() {   # compile <source>: object into ${OBJ}/o, errors into <object>.log
    local o="${OBJ}/o/$(basename "${1%.*}").o"
    [[ "$o" -nt "$1" && "$o" -nt "${HERE}/finch_prefix.h" && "$o" -nt "${HERE}/CFObjCDispatch_Finch.h" && "$o" -nt "${HERE}/CFObjCMessages_Finch.h" ]] && return 0
    case "$1" in
    *.s) "${CC}" -arch arm64e -mmacosx-version-min=26.0 -c "$1" -o "$o" ;;
    *)   "${CC}" -x objective-c "${CFLAGS[@]}" -c "$1" -o "$o" ;;
    esac 2> "$o.log" || { echo "  failed: $(basename "$1") ($(grep -c 'error:' "$o.log") errors, ${o#"${FINCH_ROOT}/"}.log)"; return 1; }
}
export -f compile; export CC OBJ HERE FINCH_ROOT
export CFLAGS_STR="$(printf '%q ' "${CFLAGS[@]}")"
# shellcheck disable=SC2086
printf '%s\n' ${srcs} | xargs -P "$(sysctl -n hw.ncpu)" -I{} bash -c 'eval "CFLAGS=(${CFLAGS_STR})"; compile "{}"' || failed=1
[[ ${failed} == 0 ]] || { echo "compile failed" >&2; exit 1; }

log "linking"
mkdir -p "${FW}/Versions/A"
# Darwin's symbol aliases (kCFLocaleCountryCode is kCFLocaleCountryCodeKey, ...),
# less the one for Swift's constant-string class.
# The compiler's constant-string class symbol is the ObjC class (CFObjC.m).
{ grep -v '^_\$s' "${CF}/DarwinSymbolAliases"
  echo '_OBJC_CLASS_$___NSCFConstantString ___CFConstantStringClassReference'; } > "${OBJ}/aliases"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
    -current_version 4424.1.255 -compatibility_version 150 -Wl,-alias_list,"${OBJ}/aliases" \
    -Wl,-init,___CFInitialize \
    "${OBJ}"/o/*.o -o "${FW}/Versions/A/CoreFoundation" -lobjc \
    -L"${ROOT}/usr/lib" -licucore -Wl,-reexport-lobjc -lSystem
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/CoreFoundation "${FW}/CoreFoundation"
codesign -f -s - -i com.apple.CoreFoundation "${FW}/Versions/A/CoreFoundation" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
