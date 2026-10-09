#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Quartz.framework: an umbrella with no code of its own, and ImageKit, which
# Apple ships inside it (Quartz.framework/Frameworks/ImageKit.framework).
#
# Apple's Quartz re-exports QuartzCore, PDFKit, QuickLookUI and its three
# subframeworks (ImageKit, QuartzComposer, QuartzFilters). Finch's re-exports
# what Finch has, QuartzCore and ImageKit, and gains the rest as they are
# written (PDFKit is a later task; QuartzComposer and QuartzFilters are
# deprecated). Loading needs only the libraries Quartz lists, so apps that
# link Quartz load; those that bind PDFKit or Quick Look symbols through it
# wait for those frameworks.
#
# ImageKit (ImageKit/): the device views Image Capture is built from
# (IKDeviceBrowserView, IKCameraDeviceView, IKScannerDeviceView) and every
# ImageKit string constant. The image browser, image view, picture taker,
# slideshow and filter UI classes come later.
#
# Linked as Apple ships them: Versions/A, Quartz and ImageKit current and
# compatibility version 1.
#
#   userland/Quartz/build.sh -> build/root/System/Library/Frameworks/Quartz.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/Quartz"
OBJ="${FINCH_ROOT}/build/obj/Quartz"
ROOT="${FINCH_ROOT}/build/root"
FWS="${ROOT}/System/Library/Frameworks"
FW="${FWS}/Quartz.framework"
IK="${FW}/Versions/A/Frameworks/ImageKit.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

for f in AppKit ImageCaptureCore QuartzCore; do
    [[ -f "${FWS}/${f}.framework/${f}" ]] || { echo "build ${f} first" >&2; exit 1; }
done

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -g -fno-objc-arc -fobjc-exceptions -fblocks -fno-common
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-objc-property-implementation -Wno-nullability -I"${HERE}")
LDFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib -F"${FWS}")

log "compiling ImageKit"
rm -rf "${OBJ}" && mkdir -p "${OBJ}"
for f in "${HERE}"/ImageKit/*.m; do
    "${CC}" "${CFLAGS[@]}" -c "$f" -o "${OBJ}/$(basename "${f%.m}").o"
done

log "linking ImageKit"
rm -rf "${FW}"
mkdir -p "${IK}/Versions/A"
"${CC}" "${LDFLAGS[@]}" \
    -install_name /System/Library/Frameworks/Quartz.framework/Versions/A/Frameworks/ImageKit.framework/Versions/A/ImageKit \
    -current_version 1 -compatibility_version 1 "${OBJ}"/*.o -o "${IK}/Versions/A/ImageKit" \
    -framework AppKit -framework Foundation -framework CoreFoundation -framework CoreGraphics \
    -framework ImageCaptureCore -lobjc
ln -sfn A "${IK}/Versions/Current"
ln -sfn Versions/Current/ImageKit "${IK}/ImageKit"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${IK}" A ImageKit com.apple.imageKit ImageKit 3.0 1233 English
codesign -f -s - -i com.apple.imageKit "${IK}/Versions/A/ImageKit" 2>/dev/null

log "linking Quartz"
REEXPORTS=(
    "${FWS}/QuartzCore.framework/QuartzCore"
    "${IK}/ImageKit"
)
# Apple's exports nothing of its own either.
echo 'static int quartz_unused __attribute__((unused));' > "${OBJ}/empty.c"
"${CC}" "${LDFLAGS[@]}" \
    -install_name /System/Library/Frameworks/Quartz.framework/Versions/A/Quartz \
    -current_version 1 -compatibility_version 1 "${OBJ}/empty.c" -o "${FW}/Versions/A/Quartz" \
    -framework Cocoa $(printf -- '-Wl,-reexport_library,%s ' "${REEXPORTS[@]}")
ln -sfn A "${FW}/Versions/Current"
ln -sfn Versions/Current/Quartz "${FW}/Quartz"
ln -sfn Versions/Current/Frameworks "${FW}/Frameworks"
"${FINCH_ROOT}/tools/mkframeworkplist.sh" "${FW}" A Quartz com.apple.quartzframework Quartz 1.5 26 English
codesign -f -s - -i com.apple.quartzframework "${FW}/Versions/A/Quartz" 2>/dev/null
log "installed ${FW#"${FINCH_ROOT}/"}"
