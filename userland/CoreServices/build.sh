#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# CoreServices.framework (docs/design/CORESERVICES.md): an umbrella that, as
# Apple's, has no code of its own and re-exports CoreFoundation and its
# subframeworks under CoreServices.framework/Frameworks. Finch's are its own
# code, compiled against the SDK's headers, each linked with Apple's install
# name, versions and umbrella so binaries' two-level bindings resolve:
#
#   CarbonCore      handles, the File Manager's FSRefs, aliases, resources, Gestalt, text encodings
#   OSServices      the odds and ends apps call (UpdateSystemActivity, ...)
#   FSEvents        file system event streams
#   Metadata        MDItem over the file system
#   LaunchServices  the UTType C API, the application database, opening, LSApplicationWorkspace & co.
#   AE              Apple event descriptors, coercion, dispatch, the Object Support Library
#   SharedFileList  LSSharedFileList (recent items) kept in the user's defaults
#
# Each exports only what Apple's does (its SDK .tbd), plus Finch's own
# cross-framework calls (_Finch*).
#
#   userland/CoreServices/build.sh -> build/root/System/Library/Frameworks/CoreServices.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/CoreServices"
OBJ="${FINCH_ROOT}/build/obj/CoreServices"
ROOT="${FINCH_ROOT}/build/root"
FWS="${ROOT}/System/Library/Frameworks"
FW="${FWS}/CoreServices.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
SDKCS="${SDKROOT}/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

for dep in Foundation UniformTypeIdentifiers; do
    [[ -f "${FWS}/${dep}.framework/${dep}" ]] || { echo "build ${dep} first" >&2; exit 1; }
done

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-common -fblocks
    -fno-objc-arc -fobjc-exceptions -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations
    -Wno-deprecated-implementations -Wno-incomplete-implementation -Wno-objc-property-implementation
    -Wno-nullability -Wno-missing-field-initializers -Wno-sign-compare -Wno-four-char-constants
    -Wno-objc-protocol-method-implementation -Wno-protocol -Wno-unused-command-line-argument)

rm -rf "${OBJ}" "${FW}"
mkdir -p "${OBJ}" "${FW}/Versions/A/Frameworks"

sub() { echo "${FW}/Versions/A/Frameworks/$1.framework/Versions/A/$1"; }

# build <name> <current version> <compatibility version> <bundle id> <short version> <bundle version> <region> [link args...]
build() {
    local name="$1" cur="$2" compat="$3" id="$4" short="$5" bver="$6" region="$7"
    shift 7
    local o="${OBJ}/${name}" dir="${FW}/Versions/A/Frameworks/${name}.framework"
    log "${name}"
    mkdir -p "${o}" "${dir}/Versions/A"
    for f in "${HERE}/${name}"/*.c "${HERE}/${name}"/*.m; do
        [[ -f "$f" ]] || continue
        "${CC}" "${CFLAGS[@]}" -I"${HERE}/${name}" -c "$f" -o "${o}/$(basename "${f%.*}").o"
    done
    # Exports: what the object files define that Apple's subframework exports, and Finch's own.
    nm -gU "${o}"/*.o | awk 'NF >= 3 {print $3}' | sort -u > "${o}/defined.txt"
    python3 - "${SDKCS}/${name}.framework/Versions/A/${name}.tbd" "${o}/defined.txt" > "${o}/exports.txt" <<'EOF'
import re, sys
doc = open(sys.argv[1]).read().split("\n--- ")[0]
apple = set()
for m in re.finditer(r"(symbols|weak-symbols|objc-classes|objc-eh-types|objc-ivars):\s*\[([^\]]*)\]", doc, re.S):
    for s in re.findall(r"'?([^,\s']+)'?", m.group(2)):
        if m.group(1) == "objc-classes":
            apple |= {"_OBJC_CLASS_$_" + s, "_OBJC_METACLASS_$_" + s}
        elif m.group(1) == "objc-eh-types":
            apple.add("_OBJC_EHTYPE_$_" + s)
        elif m.group(1) == "objc-ivars":
            apple.add("_OBJC_IVAR_$_" + s)
        else:
            apple.add(s)
for s in open(sys.argv[2]).read().split():
    if s in apple or s.startswith("__Finch"):
        print(s)
EOF
    # Apple exposes these Foundation symbols through LaunchServices too.
    # Include them in both lists so two-level bindings resolve either way.
    local reexports=()
    if [[ -f "${HERE}/${name}/Foundation.reexports" ]]; then
        cat "${HERE}/${name}/Foundation.reexports" >> "${o}/exports.txt"
        reexports=(-Wl,-reexported_symbols_list,"${HERE}/${name}/Foundation.reexports")
    fi
    "${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
        ${reexports[@]+"${reexports[@]}"} \
        -install_name "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/${name}.framework/Versions/A/${name}" \
        -current_version "${cur}" -compatibility_version "${compat}" -umbrella CoreServices \
        -Wl,-exported_symbols_list,"${o}/exports.txt" \
        "${o}"/*.o -o "${dir}/Versions/A/${name}" -F"${FWS}" -framework CoreFoundation "$@"
    ln -sfn A "${dir}/Versions/Current"
    ln -sfn "Versions/Current/${name}" "${dir}/${name}"
    "${FINCH_ROOT}/tools/mkframeworkplist.sh" "${dir}" A "${name}" "${id}" "${name}" "${short}" "${bver}" "${region}"
    codesign -f -s - -i "${id}" "${dir}/Versions/A/${name}" 2>/dev/null
}

build CarbonCore 1383.2.1 1 com.apple.CoreServices.CarbonCore 1333 1333 English
build OSServices 1141.1 1 com.apple.CoreServices.OSServices 1141.1 1141.1 English "$(sub CarbonCore)"
build FSEvents 1413.100.6 1 com.apple.CoreServices.FSEvents 1413.100.6 1413.100.6 English
build Metadata 2418.4.13 1 com.apple.Metadata 26.4 2418.4.13.404 English "$(sub CarbonCore)" -framework Foundation -lobjc
build LaunchServices 1141.1 1 com.apple.LaunchServices 1141.1 1141.1 en \
    "$(sub CarbonCore)" "$(sub Metadata)" -framework Foundation -framework UniformTypeIdentifiers -lobjc
build AE 944 1 com.apple.AE 944 944 English "$(sub CarbonCore)" "$(sub LaunchServices)"
build SharedFileList 225 1 com.apple.coreservices.SharedFileList 225 225 English \
    "$(sub CarbonCore)" "$(sub LaunchServices)" -framework Foundation -lobjc

log "CoreServices"
SUBS=(FSEvents CarbonCore Metadata OSServices AE LaunchServices SharedFileList)
echo 'const double CoreServicesVersionNumber = 1226.0;' > "${OBJ}/version.c"
"${CC}" -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /System/Library/Frameworks/CoreServices.framework/Versions/A/CoreServices \
    -current_version 1226 -compatibility_version 1 "${OBJ}/version.c" -o "${FW}/Versions/A/CoreServices" \
    -F"${FWS}" -Wl,-reexport_framework,CoreFoundation \
    $(for s in "${SUBS[@]}"; do printf -- '-Wl,-reexport_library,%s ' "$(sub "$s")"; done)
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/CoreServices "${FW}/CoreServices"
ln -sfn Versions/Current/Frameworks "${FW}/Frameworks"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A CoreServices com.apple.CoreServices CoreServices 1226 1226 en
codesign -f -s - -i com.apple.CoreServices "${FW}/Versions/A/CoreServices" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
