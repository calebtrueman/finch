#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build one of Finch's Swift frameworks to Apple's ABI: the sources compiled as the module
# Apple's has, with library evolution as Apple's is, linked into
# build/root/System/Library/Frameworks/NAME.framework (Versions/A) against Finch's frameworks.
#
#   tools/build-swift-framework.sh NAME CURRENT-VERSION source.swift|source.m... [-- link flags]
#
# Objective-C sources (.m, manual retain/release) are compiled into the same framework, and
# the Swift imports the framework's clang module (the SDK's headers) as its underlying
# module, as a mixed framework's overlay does.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="$1" VERSION="$2"; shift 2
sources=() objc=()
while [[ $# -gt 0 && "$1" != "--" ]]; do
    case "$1" in *.m) objc+=("$1") ;; *) sources+=("$1") ;; esac
    shift
done
[[ $# -gt 0 ]] && shift
OBJ="${FINCH_ROOT}/build/obj/${NAME}"
ROOT="${FINCH_ROOT}/build/root"
FW="${ROOT}/System/Library/Frameworks/${NAME}.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
log() { echo "==> $*"; }

log "compiling ${NAME}"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
objects=("${OBJ}/${NAME}-swift.o")
underlying=()
for m in ${objc[@]+"${objc[@]}"}; do
    o="${OBJ}/$(basename "${m%.m}").o"
    xcrun clang -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-objc-arc -fobjc-exceptions \
        -fblocks -Wall -Wextra -Werror -Wno-unused-parameter -Wno-objc-designated-initializers \
        -Wno-objc-property-implementation -c "${m}" -o "${o}"
    objects+=("${o}")
    underlying=(-import-underlying-module)
done
"$(xcrun -f swiftc)" -c -wmo -module-name "${NAME}" -parse-as-library -enable-library-evolution \
    -target arm64e-apple-macos26.0 -sdk "${SDKROOT}" -swift-version 5 -O ${underlying[@]+"${underlying[@]}"} \
    "${sources[@]}" -o "${OBJ}/${NAME}-swift.o" -emit-module-interface-path "${OBJ}/${NAME}.swiftinterface"

log "linking"
mkdir -p "${FW}/Versions/A"
xcrun clang -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name "/System/Library/Frameworks/${NAME}.framework/Versions/A/${NAME}" \
    -current_version "${VERSION}" -compatibility_version 1 \
    "${objects[@]}" -o "${FW}/Versions/A/${NAME}" -L"${SDKROOT}/usr/lib/swift" \
    -F"${ROOT}/System/Library/Frameworks" "$@"
ln -sfn A "${FW}/Versions/Current"
ln -sfn "Versions/Current/${NAME}" "${FW}/${NAME}"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A "${NAME}" "com.apple.${NAME}" "${NAME}" 1.0 "${VERSION}" English
codesign -f -s - -i "com.apple.${NAME}" "${FW}/Versions/A/${NAME}" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
