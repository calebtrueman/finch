#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SwiftUI.framework and SwiftUICore.framework, from OpenSwiftUI (MIT) with its open
# dependencies (OpenAttributeGraph and the rest, MIT), with modules renamed to Apple's
# (adapt.py) and every Apple private framework switched off. docs/design/SWIFTUI.md.
#   userland/SwiftUI/build.sh
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/SwiftUI"
SRC="${FINCH_ROOT}/build/src/OpenSwiftUI"
COMMIT=aefa4e6edc9c37a992a0cf9c6cf317fb670ed305
PKG="${FINCH_ROOT}/build/obj/SwiftUI-pkg"
log() { echo "==> $*"; }

if [[ "$(git -C "${SRC}" rev-parse HEAD 2>/dev/null || true)" != "${COMMIT}" ]]; then
    log "fetching OpenSwiftUI ${COMMIT}"
    rm -rf "${SRC}"
    git clone -q https://github.com/OpenSwiftUIProject/OpenSwiftUI.git "${SRC}"
    git -C "${SRC}" -c advice.detachedHead=false checkout -q "${COMMIT}"
fi
mkdir -p "${PKG}"
rsync -a --delete --exclude .build --exclude .git "${SRC}/" "${PKG}/src/"
python3 "${HERE}/adapt.py" "${PKG}/src"
log "building (SwiftPM)"
cd "${PKG}/src"
# every switch is read as OPENSWIFTUI_<name>, by OpenSwiftUI and its dependencies alike
export OPENSWIFTUI_OPENATTRIBUTESHIMS_ATTRIBUTEGRAPH=0 OPENSWIFTUI_RENDERBOX=0 OPENSWIFTUI_LINK_COREUI=0 \
    OPENSWIFTUI_LINK_CORESVG=0 OPENSWIFTUI_LINK_SFSYMBOLS=0 OPENSWIFTUI_LINK_FEATUREFLAGS=0 \
    OPENSWIFTUI_LINK_BACKLIGHTSERVICES=0 OPENSWIFTUI_LINK_GESTURES=0 OPENSWIFTUI_SYMBOL_LOCATOR=0 \
    OPENSWIFTUI_ENABLE_PRIVATE_IMPORTS=0 OPENSWIFTUI_LIBRARY_EVOLUTION=1
swift build -c release --triple arm64e-apple-macosx26.0 --scratch-path "${PKG}/build" --target SwiftUI
log "built"

# Link the frameworks: SwiftUICore with its open dependencies inside it, and SwiftUI, which
# re-exports SwiftUICore as Apple's does (apps link SwiftUI alone).
OBJS="${PKG}/build/arm64e-apple-macosx/release"
ROOT="${FINCH_ROOT}/build/root"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
FWS="${ROOT}/System/Library/Frameworks"
objs() { for m in "$@"; do find "${OBJS}/${m}.build" -name '*.o'; done; }
link() {   # link NAME VERSION objects... -- extra flags
    local name="$1" version="$2"; shift 2
    local fw="${FWS}/${name}.framework" files=() flags=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do files+=("$1"); shift; done
    [[ $# -gt 0 ]] && shift && flags=("$@")
    mkdir -p "${fw}/Versions/A"
    xcrun clang++ -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
        -install_name "/System/Library/Frameworks/${name}.framework/Versions/A/${name}" \
        -current_version "${version}" -compatibility_version 1 "${files[@]}" -o "${fw}/Versions/A/${name}" \
        -L"${SDKROOT}/usr/lib/swift" -F"${FWS}" -F"${ROOT}/System/Library/PrivateFrameworks" ${flags[@]+"${flags[@]}"}
    ln -sfn A "${fw}/Versions/Current"
    ln -sfn "Versions/Current/${name}" "${fw}/${name}"
    "${FINCH_ROOT}/tools/mkframeworkplist.sh" "${fw}" A "${name}" "com.apple.${name}" "${name}" 7.4.26 7.4.26 English
    codesign -f -s - -i "com.apple.${name}" "${fw}/Versions/A/${name}" 2>/dev/null
    log "installed ${fw#"${FINCH_ROOT}/"}"
}
log "linking"
xcrun clang -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -O2 -fdollars-in-identifiers \
    -c "${HERE}/stubs.c" -o "${PKG}/stubs.o"
mapfile -t core < <(objs SwiftUICore COpenSwiftUI OpenSwiftUI_SPI OpenAttributeGraph OpenAttributeGraphCxx \
    OpenAttributeGraphShims OpenCoreGraphicsShims OpenObservation OpenObservationCxx OpenQuartzCoreShims \
    OpenRenderBox OpenRenderBoxCxx OpenRenderBoxShims OpenRenderBoxShimsCxx)
link SwiftUICore 7.4.26 "${core[@]}" "${PKG}/stubs.o" -- -lz -framework AppKit -framework QuartzCore -framework CoreText \
    -framework Combine -framework CoreGraphics -framework Foundation -lc++
mapfile -t ui < <(objs SwiftUI)
link SwiftUI 7.4.26 "${ui[@]}" -- -Wl,-reexport_framework,SwiftUICore -framework AppKit -framework QuartzCore \
    -framework Combine -framework Foundation
