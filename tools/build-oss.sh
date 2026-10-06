#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build an Apple open-source project with its own Xcode project, against the
# public macOS SDK plus Finch's private-header overlay (tools/mksdk.sh), and
# install into the build/root staging tree that tools/vm/mkramdisk.sh overlays
# onto the VM ramdisk.
#
#   tools/build-oss.sh <project> [xcode target...]   (default target: all)
#
# Projects without a usable Xcode project get a recipe script instead:
# userland/oss/<project>.build.sh (called with SRC, OBJ, STAGE, SDKROOT,
# FINCH_SDK_CFLAGS).
#
# Keeps going past failing targets; prints which products were installed.
set -uo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
project="${1:?usage: build-oss.sh <project> [target...]}"
shift
SRC="${FINCH_ROOT}/build/src/${project}"
SDK="${FINCH_ROOT}/build/sdk"
ROOT="${FINCH_ROOT}/build/root"
LOG="${FINCH_ROOT}/build/logs/${project}.log"

[[ -d "${SRC}" ]] || { echo "error: ${SRC} missing (tools/fetch-src.sh ${project})" >&2; exit 1; }
[[ -d "${SDK}" ]] || { echo "error: ${SDK} missing (tools/mksdk.sh)" >&2; exit 1; }
mkdir -p "${ROOT}" "$(dirname "${LOG}")"

if [[ $# -gt 0 ]]; then
    targets=()
    for t in "$@"; do targets+=(-target "$t"); done
else
    targets=(-alltargets)
fi

# Apple's internal base config isn't published; point includes at Finch's.
grep -rl --include='*.xcconfig' 'Makefiles/CoreOS/Xcode/BSD.xcconfig' "${SRC}" 2>/dev/null \
    | while read -r f; do
        sed -i '' 's|"<DEVELOPER_DIR>/Makefiles/CoreOS/Xcode/BSD.xcconfig"|"'"${FINCH_ROOT}"'/userland/sdk/BSD.xcconfig"|' "$f"
    done

# Per-project Finch overrides (use $(inherited) to extend project settings).
xcconfig=()
[[ -f "${FINCH_ROOT}/userland/oss/${project}.xcconfig" ]] \
    && xcconfig=(-xcconfig "${FINCH_ROOT}/userland/oss/${project}.xcconfig")

# Stage into a per-project DSTROOT, then merge, so we know exactly what this
# project produced.
stage="${FINCH_ROOT}/build/stage/${project}"
rm -rf "${stage}"

recipe="${FINCH_ROOT}/userland/oss/${project}.build.sh"
if [[ -x "${recipe}" ]]; then
    # Non-Xcode project: run Finch's build recipe instead.
    SRC="${SRC}" OBJ="${FINCH_ROOT}/build/obj/${project}" STAGE="${stage}" \
        FINCH_SDK_CFLAGS="-idirafter ${SDK}/include -F${SDK}/Frameworks" \
        SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" "${recipe}" > "${LOG}" 2>&1
else
xcodebuild install "${targets[@]}" -project "${SRC}/${project}.xcodeproj" ${xcconfig[@]+"${xcconfig[@]}"} \
    -sdk macosx ARCHS=arm64e ONLY_ACTIVE_ARCH=NO \
    DSTROOT="${stage}" \
    OBJROOT="${FINCH_ROOT}/build/obj/${project}" \
    SYMROOT="${FINCH_ROOT}/build/sym/${project}" \
    CODE_SIGNING_ALLOWED=NO \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    OTHER_CFLAGS='$(inherited) -Wno-error -idirafter '"${SDK}/include"' -F'"${SDK}/Frameworks" \
    -IDEBuildingContinueBuildingAfterErrors=YES \
    > "${LOG}" 2>&1
fi
status=$?

# Drop Apple-internal test payloads; sign every Mach-O (ad hoc) for the trust cache.
rm -rf "${stage}/AppleInternal" "${stage}/usr/local/share/"*tests* 2>/dev/null
installed=0
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then
        codesign -f -s - "$f" 2>/dev/null
        installed=$((installed + 1))
    fi
done < <(find "${stage}" -type f -print0 2>/dev/null)
[[ -d "${stage}" ]] && rsync -a "${stage}/" "${ROOT}/"

failed=$(grep -E '^\S+: (fatal )?error:' "${LOG}" | sed -E 's|^.*/'"${project}"'/([^/]+)/.*|\1|' | sort -u | tr '\n' ' ')
echo "${project}: ${installed} Mach-O installed into build/root (build exit ${status})"
[[ -n "${failed}" ]] && echo "  failed in: ${failed}  (see ${LOG#"${FINCH_ROOT}/"})"
exit 0
