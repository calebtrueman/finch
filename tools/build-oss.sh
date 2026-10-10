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
# FINCH_SDK_CFLAGS, FINCH_PRIVATE_CFLAGS).
#
# Keeps going past failing targets; prints which products were installed.
set -uo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
project="${1:?usage: build-oss.sh <project> [target...]}"
shift
SRC="${FINCH_ROOT}/build/src/${project}"
SDK="${FINCH_ROOT}/build/sdk"
ROOT="${FINCH_OSS_ROOT:-${FINCH_ROOT}/build/root}"   # FINCH_OSS_ROOT: install elsewhere (e.g. to survey a build)
LOG="${FINCH_ROOT}/build/logs/${project}.log"

[[ -d "${SRC}" ]] || { echo "error: ${SRC} missing (tools/fetch-src.sh ${project})" >&2; exit 1; }
[[ -d "${SDK}" ]] || { echo "error: ${SDK} missing (tools/mksdk.sh)" >&2; exit 1; }
mkdir -p "${ROOT}" "$(dirname "${LOG}")"

# Builds never prompt: a stand-in osascript, first on PATH, refuses the
# "with administrator privileges" dialogs some Apple projects try to raise.
nogui="${FINCH_ROOT}/build/obj/.nogui"
mkdir -p "${nogui}"
cat > "${nogui}/osascript" <<'EOT'
#!/bin/sh
echo "build-oss: refused osascript (no GUI prompts in builds): $*" >&2
exit 1
EOT
chmod +x "${nogui}/osascript"
export PATH="${nogui}:${PATH}"

if [[ $# -gt 0 ]]; then
    targets=()
    for t in "$@"; do targets+=(-target "$t"); done
else
    targets=(-alltargets)
fi

# Finch patches to this project (userland/patches/<project>/*.patch), applied
# idempotently to the build/src checkout.
for p in "${FINCH_ROOT}/userland/patches/${project}"/*.patch; do
    [[ -f "$p" ]] || continue
    if git -C "${SRC}" apply --check "$p" 2>/dev/null; then
        git -C "${SRC}" apply "$p"
    elif ! git -C "${SRC}" apply --check --reverse "$p" 2>/dev/null; then
        echo "error: patch does not apply: $p" >&2; exit 1
    fi
done

# Optional pre-build step (e.g. generated headers), run in the source tree.
if [[ -x "${FINCH_ROOT}/userland/oss/${project}.pre.sh" ]]; then
    (cd "${SRC}" && "${FINCH_ROOT}/userland/oss/${project}.pre.sh") \
        || { echo "error: ${project}.pre.sh failed" >&2; exit 1; }
fi

# Apple's internal base config isn't published; point includes at Finch's.
grep -rl --include='*.xcconfig' 'Makefiles/CoreOS/Xcode/BSD.xcconfig' "${SRC}" 2>/dev/null \
    | while read -r f; do
        sed -i '' 's|"<DEVELOPER_DIR>/Makefiles/CoreOS/Xcode/BSD.xcconfig"|"'"${FINCH_ROOT}"'/userland/sdk/BSD.xcconfig"|' "$f"
    done

# Projects that are part of libSystem itself need xnu's private headers (and a
# matching Availability set) ahead of the public SDK. Opt in with a marker file.
fr="${FINCH_ROOT}/build/xnu-work/fakeroot"
# dyld's OS version sets, past the 2023 ones AvailabilityVersions publishes (idempotent)
[[ -f "${fr}/usr/local/include/dyld/VersionMap.h" ]] &&
    python3 "${FINCH_ROOT}/tools/extend-version-map.py" "${fr}/usr/local/include/dyld/VersionMap.h"
private_first="-I${SDK}/override -I${SDK}/availability -I${fr}/System/Library/Frameworks/System.framework/Versions/B/PrivateHeaders -I${fr}/usr/local/include"
cflags_private=""
is_private_first=""
[[ -f "${FINCH_ROOT}/userland/oss/${project}.private-first" ]] \
    && cflags_private="${private_first}" is_private_first=1
# Declarations Apple's internal headers would supply (force-included).
[[ -f "${FINCH_ROOT}/userland/oss/${project}.prelude.h" ]] \
    && cflags_private+=" -include ${FINCH_ROOT}/userland/oss/${project}.prelude.h"


# Xcode's incremental builds don't notice changes to the Finch inputs above
# (e.g. new linker flags), so fingerprint them and build clean on any change.
obj="${FINCH_ROOT}/build/obj/${project}"
inputs_hash=$(cat "${FINCH_ROOT}/userland/oss/${project}".* \
        "${FINCH_ROOT}/userland/patches/${project}"/*.patch \
        "${FINCH_ROOT}/userland/sdk/BSD.xcconfig" "${FINCH_ROOT}/tools/build-oss.sh" 2>/dev/null \
    | cat - <(find "${SDK}" -type f -print0 | xargs -0 shasum 2>/dev/null) | shasum | cut -c1-16)
if [[ "$(cat "${obj}/.finch-inputs" 2>/dev/null)" != "${inputs_hash}" ]]; then
    rm -rf "${obj}" "${FINCH_ROOT}/build/sym/${project}"
fi
mkdir -p "${obj}"
echo "${inputs_hash}" > "${obj}/.finch-inputs"

# Stage into a per-project DSTROOT, then merge, so we know exactly what this
# project produced.
stage="${FINCH_ROOT}/build/stage/${project}"
# A background indexer can still be writing into the old tree; retry once. A
# stage holding root-owned files (from a build run as root) can't be removed
# unprivileged: move it aside to build/stage/.stale for a later `sudo rm`.
rm -rf "${stage}" 2>/dev/null || { sleep 1; rm -rf "${stage}" 2>/dev/null; } || {
    mkdir -p "${FINCH_ROOT}/build/stage/.stale"
    mv "${stage}" "${FINCH_ROOT}/build/stage/.stale/${project}-$(date +%s)"
    echo "note: moved a stage with root-owned files to build/stage/.stale (sudo rm -rf it)" >&2
}

# The Xcode project is usually <project>.xcodeproj; otherwise use the only one.
xcodeproj="${SRC}/${project}.xcodeproj"
if [[ ! -d "${xcodeproj}" ]]; then
    shopt -s nullglob
    projs=("${SRC}"/*.xcodeproj)
    shopt -u nullglob
    [[ ${#projs[@]} -eq 1 ]] && xcodeproj="${projs[0]}"
fi

recipe="${FINCH_ROOT}/userland/oss/${project}.build.sh"
if [[ -x "${recipe}" ]]; then
    # Non-Xcode project: run Finch's build recipe instead.
    SRC="${SRC}" OBJ="${FINCH_ROOT}/build/obj/${project}" STAGE="${stage}" \
        FINCH_SDK_CFLAGS="-idirafter ${SDK}/include -F${SDK}/Frameworks" \
        FINCH_PRIVATE_CFLAGS="${private_first}" \
        SDKROOT="$(xcrun --sdk macosx --show-sdk-path)" "${recipe}" > "${LOG}" 2>&1
else
# Finch settings go in one generated xcconfig: per-project overrides
# (userland/oss/<project>.xcconfig) plus our compiler flags, appended to the
# project's own OTHER_CFLAGS via $(inherited).
# Static libraries Finch provides for Apple-internal ones (libCrashReporterClient.a).
make -s -C "${FINCH_ROOT}/userland/CrashReporterClient" >/dev/null \
    || { echo "error: building libCrashReporterClient.a failed" >&2; exit 1; }
finch_xcconfig="${obj}/finch.xcconfig"
{
    echo "// Generated by tools/build-oss.sh"
    echo "FINCH_ROOT = ${FINCH_ROOT}"
    [[ -f "${FINCH_ROOT}/userland/oss/${project}.xcconfig" ]] \
        && echo "#include \"${FINCH_ROOT}/userland/oss/${project}.xcconfig\""
    echo "LIBRARY_SEARCH_PATHS = \$(inherited) ${FINCH_ROOT}/build/userland/lib"
    # Executables drop libraries they use nothing from: Apple's projects link
    # some (IOKit in halt, SystemConfiguration in dynamic_pager) that are closed
    # and absent from Finch's image (tools/check-closed.py). Libraries keep
    # their links, which match Apple's on purpose. A project's own link flags
    # are FINCH_PROJECT_LDFLAGS in its userland/oss/<project>.xcconfig.
    # Apple's builds run projects' script phases unsandboxed (they generate
    # headers and install files in the source and staging trees).
    echo "ENABLE_USER_SCRIPT_SANDBOXING = NO"
    echo "FINCH_DEAD_STRIP_mh_execute = -Wl,-dead_strip_dylibs"
    echo "OTHER_LDFLAGS = \$(inherited) \$(FINCH_PROJECT_LDFLAGS) \$(FINCH_DEAD_STRIP_\$(MACH_O_TYPE))"
    # Finch's own headers (userland/sdk/include, in ${SDK}/override) come first
    # for private-first projects, and after everything else for the rest, so
    # they only fill in what the SDK lacks.
    # (Not both: clang drops a -I directory that's also a system directory,
    # which would silently move the overlay to the end.)
    # (The private availability macros, last of all, for xnu private headers
    # such as <sys/resource_private.h> that need them.)
    overlay_after="-idirafter ${SDK}/override -idirafter ${SDK}/availability"
    [[ -n "${is_private_first}" ]] && overlay_after=""
    echo "OTHER_CFLAGS = \$(inherited) -Wno-error ${cflags_private} -idirafter ${SDK}/include ${overlay_after} -F${SDK}/Frameworks"
    # mig preprocesses .defs files, which import private .defs and headers too.
    echo "OTHER_MIGFLAGS = \$(inherited) -I${SDK}/override -I${SDK}/include"
    # TAPI re-parses the installed headers to build .tbd files; it needs the
    # same header order as the compiler, or private availability macros fail.
    [[ -n "${is_private_first}" ]] \
        && echo "OTHER_TAPI_FLAGS = \$(inherited) ${private_first} -idirafter ${SDK}/include -F${SDK}/Frameworks"
} > "${finch_xcconfig}"

xcodebuild install "${targets[@]}" -project "${xcodeproj}" -xcconfig "${finch_xcconfig}" \
    -sdk macosx ARCHS=arm64e ONLY_ACTIVE_ARCH=NO \
    DSTROOT="${stage}" \
    OBJROOT="${FINCH_ROOT}/build/obj/${project}" \
    SYMROOT="${FINCH_ROOT}/build/sym/${project}" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    GCC_TREAT_WARNINGS_AS_ERRORS=NO \
    -IDEBuildingContinueBuildingAfterErrors=YES \
    > "${LOG}" 2>&1
fi
status=$?

# Drop Apple-internal test payloads; sign every Mach-O (ad hoc) for the trust cache,
# keeping the entitlements Xcode embedded from each target's CODE_SIGN_ENTITLEMENTS
# (ps reads other tasks, notifyd and the configd daemons need theirs).
rm -rf "${stage}/AppleInternal" "${stage}/usr/local/share/"*tests* 2>/dev/null
# Sign every Mach-O ad hoc, keeping the entitlements Xcode embedded.
sign_keeping_entitlements() {   # sign_keeping_entitlements <mach-o>
    codesign -f -s - --preserve-metadata=entitlements,identifier "$1" 2>/dev/null \
        || codesign -f -s - "$1" 2>/dev/null
}
installed=0
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then
        sign_keeping_entitlements "$f"
        installed=$((installed + 1))
    fi
done < <(find "${stage}" -type f -print0 2>/dev/null)
[[ -d "${stage}" ]] && rsync -a "${stage}/" "${ROOT}/"

# Licence notices that must travel with the binaries (docs/LICENSING.md):
# userland/oss/<project>.notices lists files in the source tree to install.
if [[ -f "${FINCH_ROOT}/userland/oss/${project}.notices" ]]; then
    notices="${ROOT}/usr/share/finch/licenses/${project}"
    mkdir -p "${notices}"
    grep -v '^\s*#' "${FINCH_ROOT}/userland/oss/${project}.notices" | sed '/^\s*$/d' \
        | while read -r file; do cp "${SRC}/${file}" "${notices}/"; done
fi

# Source directories (≈ targets) with errors; errors in SDK headers they include
# count against the project directory that included them.
failed=$(grep -E '^\S+: (fatal )?error:' "${LOG}" | grep "/build/src/${project}/" \
    | sed -E 's|^.*/build/src/'"${project}"'/([^/:]+)[/:].*|\1|' | sort -u | tr '\n' ' ')
echo "${project}: ${installed} Mach-O installed into build/root (build exit ${status})"
[[ -n "${failed}" ]] && echo "  failed in: ${failed}  (see ${LOG#"${FINCH_ROOT}/"})"
exit 0
