#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Skia (BSD-3-Clause), the 2D renderer under Finch's CoreGraphics
# (docs/design/COREGRAPHICS.md). Pinned to the chrome/m155 branch commit below;
# the third-party libraries it builds against are fetched shallow at the commits
# that commit's DEPS file pins. Only the CPU raster backend is built, with
# FreeType for glyphs, and patches/0001 keeps Skia off Apple's CoreGraphics,
# ImageIO and CoreText.
#
#   userland/skia/build.sh   -> build/obj/skia/*.a (static, linked into CoreGraphics)
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/skia"
SKIA_COMMIT=29ed1e87a0a50f3d8347e988842d9d59e7573efa   # chrome/m155
SRC="${FINCH_ROOT}/build/src/skia"
OBJ="${FINCH_ROOT}/build/obj/skia"
ROOT="${FINCH_ROOT}/build/root"
log() { echo "==> $*"; }

# fetch <dir> <url> <commit>: shallow checkout of one commit.
fetch() {
    local dir="$1" url="$2" commit="$3"
    [[ "$(git -C "${dir}" rev-parse HEAD 2>/dev/null)" == "${commit}" ]] && return
    log "fetching ${dir#${SRC}/} ${commit:0:12}"
    rm -rf "${dir}" && mkdir -p "${dir}"
    git -C "${dir}" init -q
    git -C "${dir}" fetch -q --depth 1 "${url}" "${commit}"
    git -C "${dir}" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

fetch "${SRC}" https://skia.googlesource.com/skia "${SKIA_COMMIT}"
DEPS=(expat freetype harfbuzz libjpeg-turbo libpng libwebp wuffs zlib)
for dep in "${DEPS[@]}"; do
    spec=$(sed -n "s|^ *\"third_party/externals/${dep}\" *: *\"\(.*\)\",|\1|p" "${SRC}/DEPS")
    [[ -n "${spec}" ]] || { echo "skia: ${dep} not in DEPS" >&2; exit 1; }
    fetch "${SRC}/third_party/externals/${dep}" "${spec%@*}" "${spec##*@}"
done
[[ -x "${SRC}/bin/gn" ]] || { log "fetching gn"; python3 "${SRC}/bin/fetch-gn"; }

for p in "${HERE}"/patches/*.patch; do
    if git -C "${SRC}" apply --check "${p}" 2>/dev/null; then
        git -C "${SRC}" apply "${p}"
    elif ! git -C "${SRC}" apply --check -R "${p}" 2>/dev/null; then
        echo "skia: ${p##*/} does not apply" >&2; exit 1
    fi
done

TARGET='"-target","arm64e-apple-macos26.0"'
ARGS=(
    is_official_build=true is_debug=false target_cpu=\"arm64\"
    "extra_cflags=[${TARGET}]" "extra_asmflags=[${TARGET}]" "extra_ldflags=[${TARGET}]"
    skia_use_apple_frameworks=false skia_use_fonthost_mac=false
    skia_use_partition_alloc=false
    # CPU raster only
    skia_use_gl=false skia_use_metal=false skia_use_vulkan=false skia_use_dawn=false
    skia_enable_ganesh=false skia_enable_graphite=false
    # glyphs from FreeType; CoreText (shaping, font matching) is Finch's own
    skia_use_freetype=true skia_use_system_freetype2=false skia_enable_fontmgr_empty=true
    skia_use_harfbuzz=false skia_use_icu=false skia_use_expat=false
    # codecs for ImageIO, all bundled
    skia_use_system_libpng=false skia_use_system_libjpeg_turbo=false
    skia_use_system_libwebp=false skia_use_system_zlib=false skia_use_wuffs=true
    skia_use_dng_sdk=false skia_use_piex=false skia_use_libavif=false
    skia_use_libjxl_decode=false skia_use_ffmpeg=false
    # PDF backend for CGPDFContext
    skia_enable_pdf=true skia_pdf_subset_harfbuzz=false
    skia_enable_svg=false skia_enable_skottie=false skia_enable_skshaper=false
    skia_enable_skparagraph=false skia_enable_tools=false skia_use_xps=false
)
log "configuring"
(cd "${SRC}" && bin/gn gen "${OBJ}" --args="${ARGS[*]}" > /dev/null)
log "building"
ninja -C "${OBJ}" skia > "${OBJ}/ninja.log" 2>&1 || { tail -20 "${OBJ}/ninja.log"; exit 1; }

# Skia must not reach Apple's graphics frameworks (see the patch).
if nm -u "${OBJ}/libskia.a" | grep -qE '^_(CG|CT|kCG|kCT)'; then
    echo "skia: libskia.a references CoreGraphics/CoreText" >&2; exit 1
fi

mkdir -p "${ROOT}/usr/share/finch/licenses/skia"
cp "${SRC}/LICENSE" "${ROOT}/usr/share/finch/licenses/skia/LICENSE"
for dep in freetype libjpeg-turbo libpng libwebp wuffs zlib; do
    d="${SRC}/third_party/externals/${dep}"
    lic=$(ls "${d}"/LICENSE* "${d}"/COPYING* "${d}"/LICENSE.md "${d}"/docs/FTL.TXT 2>/dev/null | head -1 || true)
    [[ -n "${lic}" ]] && cp "${lic}" "${ROOT}/usr/share/finch/licenses/skia/${dep}-$(basename "${lic}")"
done
log "built build/obj/skia/libskia.a"
