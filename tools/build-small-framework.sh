#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build one of Finch's small C / Objective-C frameworks (or a dylib) to Apple's ABI:
# compiled against the SDK's headers, linked with Apple's install name and versions,
# its Info.plist written and the binary signed.
#
#   tools/build-small-framework.sh INSTALL_PATH CURRENT COMPAT BUNDLE_ID SHORT_VERSION SOURCE... [-- LINK_FLAGS...]
#
# INSTALL_PATH is the install name, e.g.
#   /System/Library/Frameworks/ColorSync.framework/Versions/A/ColorSync
#   /System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/HIToolbox
#   /usr/lib/libScreenReader.dylib
# Frameworks get Versions/Current and the top-level links; BUNDLE_ID "-" skips the plist.
# Sources are .c, .m or .cpp; Objective-C is built without ARC. CFLAGS in the
# environment are added to every compile (e.g. -I for a library's headers).
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
CXX="$(xcrun -f clang++)"
log() { echo "==> $*"; }

INSTALL="$1" CURRENT="$2" COMPAT="$3" BUNDLE_ID="$4" SHORT="$5"
shift 5
SOURCES=()
while [[ $# -gt 0 && "$1" != "--" ]]; do SOURCES+=("$1"); shift; done
[[ $# -gt 0 ]] && shift
LINK=("$@")

NAME="$(basename "${INSTALL}")"
OUT="${ROOT}${INSTALL}"
OBJ="${FINCH_ROOT}/build/obj/${NAME}"
FLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fblocks ${CFLAGS:-}
       -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations)

log "compiling ${NAME}"
rm -rf "${OBJ}" && mkdir -p "${OBJ}" "$(dirname "${OUT}")"
OBJS=()
for src in "${SOURCES[@]}"; do
    o="${OBJ}/$(basename "${src%.*}").o"
    case "${src}" in
    *.cpp) "${CXX}" "${FLAGS[@]}" -std=c++20 -c "${src}" -o "${o}" ;;
    *.m)   "${CC}" "${FLAGS[@]}" -fno-objc-arc -c "${src}" -o "${o}" ;;
    *)     "${CC}" "${FLAGS[@]}" -c "${src}" -o "${o}" ;;
    esac
    OBJS+=("${o}")
done

log "linking ${NAME}"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name "${INSTALL}" -current_version "${CURRENT}" -compatibility_version "${COMPAT}" \
    "${OBJS[@]}" -o "${OUT}" \
    -F"${ROOT}/System/Library/Frameworks" -F"${ROOT}/System/Library/PrivateFrameworks" ${LINK[@]+"${LINK[@]}"}

case "${INSTALL}" in
*.framework/Versions/A/*)
    FW="${OUT%/Versions/A/*}"
    ln -sfn A "${FW}/Versions/Current"
    ln -sfn "Versions/Current/${NAME}" "${FW}/${NAME}"
    if [[ "${BUNDLE_ID}" != "-" ]]; then
        "${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A "${NAME}" "${BUNDLE_ID}" "${NAME}" "${SHORT}" "${CURRENT}" English
    fi
    ;;
esac
codesign -f -s - ${BUNDLE_ID:+$([[ "${BUNDLE_ID}" != "-" ]] && echo "-i ${BUNDLE_ID}")} "${OUT}" 2>/dev/null
log "installed ${OUT#"${FINCH_ROOT}/"}"
