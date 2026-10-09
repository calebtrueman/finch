#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# The fonts Finch ships in place of Apple's, which can't be redistributed.
# Every font has an open licence, is pinned by SHA-256, and is installed
# unchanged, from fixed release downloads. CoreText
# and CoreGraphics map Apple's font names onto them (userland/fonts/FinchFonts.h; docs/design/COREGRAPHICS.md,
# "Fonts").
#
#   userland/fonts/build.sh  -> build/root/System/Library/Fonts/*.{ttf,otf}
#                               build/root/usr/share/finch/licenses/<font>/
#
# What ships and why (the CJK pair is about 32 MB):
#   Inter 4.1 (OFL-1.1)              system/UI font (SF Pro): every weight, with italics
#   Open Runde 1.0.1 (OFL-1.1)       SF Pro Rounded: regular, medium, semibold, bold
#   Fragment Mono 1.21 (OFL-1.1)     SF Mono regular and italic
#   XCharter 1.26 (Bitstream free)   Charter: regular, bold, italic, bold italic
#   TeX Gyre Pagella 2.501 (GFL)     Palatino: regular, bold, italic, bold italic
#   Liberation 2.1.5 (OFL-1.1)       Arial/Helvetica, Times, Courier: metric-compatible
#   DejaVu Sans Mono 2.37 (Bitstream Vera + public domain)
#                                    Menlo, Monaco, and bold SF Mono requests:
#                                    Fragment Mono has no bold face
#   Noto Sans, Noto Serif 2.015 (OFL-1.1)   Latin, Greek, Cyrillic fallback
#   Noto Sans Symbols 2.003, Symbols 2 2.008 (OFL-1.1)
#   Noto Sans Arabic 2.013, Noto Sans Hebrew 3.001 (OFL-1.1)  right-to-left scripts
#   Noto Sans CJK SC 2.004 Regular and Bold (OFL-1.1): every Noto CJK face covers
#                                    Chinese, Japanese kana and Korean hangul; SC
#                                    because Apple's default Han fallback is PingFang SC
#   Noto Color Emoji 2.051 (OFL-1.1) CBDT colour bitmaps (FreeType reads them
#                                    with Skia's PNG support)
# Noto fonts are the unhinted builds: Finch draws glyphs unhinted, as Apple does.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DL="${FINCH_ROOT}/build/src/upstream-dl/fonts"
SRC="${FINCH_ROOT}/build/src/fonts"
ROOT="${FINCH_ROOT}/build/root"
FONTS="${ROOT}/System/Library/Fonts"
LICENSES="${ROOT}/usr/share/finch/licenses"
log() { echo "==> $*"; }

# fetch <file> <sha256> <url>: download once into build/src/upstream-dl/fonts, verified.
fetch() {
    local f="${DL}/$1"
    if [[ "$(shasum -a 256 "${f}" 2>/dev/null | cut -c1-64)" != "$2" ]]; then
        log "fetching $1"
        mkdir -p "${DL}"
        curl -sfL -o "${f}" "$3"
        [[ "$(shasum -a 256 "${f}" | cut -c1-64)" == "$2" ]] || { echo "fonts: checksum mismatch: $1" >&2; exit 1; }
    fi
}
# unpack <archive>: into build/src/fonts/<archive name without extension>.
unpack() {
    local d="${SRC}/${1%%.[tz][ai][rp]*}"
    [[ -d "${d}" ]] && { echo "${d}"; return; }
    mkdir -p "${d}.tmp"
    case "$1" in
        *.zip) unzip -q -o "${DL}/$1" -d "${d}.tmp" ;;
        *) tar -xf "${DL}/$1" -C "${d}.tmp" ;;
    esac
    mv "${d}.tmp" "${d}"
    echo "${d}"
}
# install_fonts <license dir name> <license file> <font files...>
install_fonts() {
    local name="$1" lic="$2"; shift 2
    mkdir -p "${FONTS}" "${LICENSES}/${name}"
    install -m 644 "$@" "${FONTS}/"
    install -m 644 "${lic}" "${LICENSES}/${name}/"
}

mkdir -p "${SRC}"

fetch Inter-4.1.zip 9883fdd4a49d4fb66bd8177ba6625ef9a64aa45899767dde3d36aa425756b11e \
    https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip
d=$(unpack Inter-4.1.zip)
faces=()
for w in Thin ExtraLight Light Regular Medium SemiBold Bold ExtraBold Black; do
    faces+=("${d}/extras/ttf/Inter-${w}.ttf")
    [[ ${w} == Regular ]] && faces+=("${d}/extras/ttf/Inter-Italic.ttf") || faces+=("${d}/extras/ttf/Inter-${w}Italic.ttf")
done
install_fonts Inter "${d}/LICENSE.txt" "${faces[@]}"

fetch OpenRunde-1.0.1.zip 8043a338cc8ec78ed1bc0012aa779410eff68957a71004ff7b99306ddfaa1d41 \
    https://github.com/lauridskern/open-runde/releases/download/v1.0.1/OpenRunde-1.0.1.zip
fetch OpenRunde-LICENSE-1.0.1.txt 262481e844521b326f5ecd053e59b98c8b2da78c8ee1bdbb6e8174305e54935a \
    https://raw.githubusercontent.com/lauridskern/open-runde/v1.0.1/LICENSE.txt
d=$(unpack OpenRunde-1.0.1.zip)/OpenRunde-1.0.1
install_fonts OpenRunde "${DL}/OpenRunde-LICENSE-1.0.1.txt" \
    "${d}"/desktop/OpenRunde-{Regular,Medium,Semibold,Bold}.otf

fetch fragment-mono-1.21.zip 1d3b711facfb0621638dc650708f8a26dbe83b1efb4382a2438ac5eadb716658 \
    https://github.com/weiweihuanghuang/fragment-mono/releases/download/1.21/fragment-mono-1.21.zip
d=$(unpack fragment-mono-1.21.zip)/fragment-mono-1.21
install_fonts FragmentMono "${d}/OFL.txt" "${d}"/fonts/otf/FragmentMono-{Regular,Italic}.otf

# CTAN's main zip URLs change with each update. These frozen TeX Live archives
# have fixed revision names and contain the same font files used in our test.
TEXLIVE=https://ftp.math.utah.edu/pub/tex/historic/systems/texlive/2025/tlnet-final/archive
fetch xcharter.r71564.tar.xz 8fc717152ae6ef683ebb982fbf20837f85ff03a5b440fd84b0b11eac7c14b523 \
    "${TEXLIVE}/xcharter.r71564.tar.xz"
fetch xcharter.doc.r71564.tar.xz 30a5aa924cab044820a208502cd94685357df968457d01a0dea6a8f1df2e4fa0 \
    "${TEXLIVE}/xcharter.doc.r71564.tar.xz"
d=$(unpack xcharter.r71564.tar.xz)
doc=$(unpack xcharter.doc.r71564.tar.xz)
install_fonts XCharter "${doc}/doc/fonts/xcharter/README" \
    "${d}"/fonts/opentype/public/xcharter/XCharter-{Roman,Bold,Italic,BoldItalic}.otf

fetch tex-gyre.r68624.tar.xz dfb4f55c4b02993003777a48663987bd102a3c5a2913172571e05fe2eb18407d \
    "${TEXLIVE}/tex-gyre.r68624.tar.xz"
fetch tex-gyre.doc.r68624.tar.xz c81a8ac0381e34c55b0075aec75e6646b69bb7b428ebb7d1eca337001f1ef08c \
    "${TEXLIVE}/tex-gyre.doc.r68624.tar.xz"
d=$(unpack tex-gyre.r68624.tar.xz)
doc=$(unpack tex-gyre.doc.r68624.tar.xz)
install_fonts TeXGyrePagella "${doc}/doc/fonts/tex-gyre/GUST-FONT-LICENSE.txt" \
    "${d}"/fonts/opentype/public/tex-gyre/texgyrepagella-{regular,bold,italic,bolditalic}.otf
install -m 644 "${doc}/doc/fonts/tex-gyre/README-TeX-Gyre-Pagella.txt" "${LICENSES}/TeXGyrePagella/"

fetch liberation-fonts-ttf-2.1.5.tar.gz 7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0 \
    https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz
d=$(unpack liberation-fonts-ttf-2.1.5.tar.gz)/liberation-fonts-ttf-2.1.5
install_fonts Liberation "${d}/LICENSE" "${d}"/Liberation{Sans,Serif,Mono}-{Regular,Bold,Italic,BoldItalic}.ttf

fetch dejavu-fonts-ttf-2.37.tar.bz2 fa9ca4d13871dd122f61258a80d01751d603b4d3ee14095d65453b4e846e17d7 \
    https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.tar.bz2
d=$(unpack dejavu-fonts-ttf-2.37.tar.bz2)/dejavu-fonts-ttf-2.37
install_fonts DejaVu "${d}/LICENSE" "${d}"/ttf/DejaVuSansMono{,-Bold,-Oblique,-BoldOblique}.ttf

# noto <family> <tag> <sha256> <repo> <styles...>: a notofonts release zip.
noto() {
    local fam="$1" tag="$2" sum="$3" repo="$4"; shift 4
    fetch "${fam}-${tag}.zip" "${sum}" "https://github.com/notofonts/${repo}/releases/download/${fam}-${tag}/${fam}-${tag}.zip"
    local d files=() s
    d=$(unpack "${fam}-${tag}.zip")
    for s in "$@"; do files+=("${d}/${fam}/unhinted/ttf/${fam}-${s}.ttf"); done
    install_fonts "${fam}" "${d}/OFL.txt" "${files[@]}"
}
noto NotoSans v2.015 0c34df072a3fa7efbb7cbf34950e1f971a4447cffe365d3a359e2d4089b958f5 latin-greek-cyrillic Regular Bold Italic BoldItalic
noto NotoSerif v2.015 0e9a43c8a4b94ac76f55069ed1d7385bbcaf6b99527a94deb5619e032b7e76c1 latin-greek-cyrillic Regular Bold Italic BoldItalic
noto NotoSansSymbols v2.003 0c113cdcf6c31d050b80dac39fba2d804a6985281012e76e9220c0a00da007f3 symbols Regular
noto NotoSansSymbols2 v2.008 346c930bbe8eb946701a05c54e9c11a2094dee1d93c387bf1771c0a3e335688f symbols Regular
noto NotoSansArabic v2.013 1301aceaea84c501cf2e6dcfb3182e2328c8eae5725817fcb239672bda7154f1 arabic Regular Bold
noto NotoSansHebrew v3.001 df0a71814b4e63644cf40fcc4529111b61266b7a2dafbe95068b29a7520cc3cb hebrew Regular Bold

# Noto Sans CJK and Noto Color Emoji publish their fonts in the repository at
# the release tag; single files are fetched rather than the 95 MB release zip.
CJK=https://raw.githubusercontent.com/notofonts/noto-cjk/Sans2.004
fetch NotoSansCJKsc-Regular-2.004.otf 2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b \
    "${CJK}/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf"
fetch NotoSansCJKsc-Bold-2.004.otf b5f0d1a190a7f9b43c310a8850630af12553df32c4c050543f9059732d9b4c0a \
    "${CJK}/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Bold.otf"
fetch NotoSansCJK-LICENSE-2.004 6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2 "${CJK}/LICENSE"
mkdir -p "${FONTS}" "${LICENSES}/NotoSansCJK"
install -m 644 "${DL}/NotoSansCJKsc-Regular-2.004.otf" "${FONTS}/NotoSansCJKsc-Regular.otf"
install -m 644 "${DL}/NotoSansCJKsc-Bold-2.004.otf" "${FONTS}/NotoSansCJKsc-Bold.otf"
install -m 644 "${DL}/NotoSansCJK-LICENSE-2.004" "${LICENSES}/NotoSansCJK/LICENSE"

EMOJI=https://raw.githubusercontent.com/googlefonts/noto-emoji/v2.051/fonts
fetch NotoColorEmoji-2.051.ttf 72a635cb3d2f3524c51620cdde406b217204e8a6a06c6a096ff8ed4b5fd6e27b "${EMOJI}/NotoColorEmoji.ttf"
fetch NotoColorEmoji-LICENSE-2.051 6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2 "${EMOJI}/LICENSE"
mkdir -p "${LICENSES}/NotoColorEmoji"
install -m 644 "${DL}/NotoColorEmoji-2.051.ttf" "${FONTS}/NotoColorEmoji.ttf"
install -m 644 "${DL}/NotoColorEmoji-LICENSE-2.051" "${LICENSES}/NotoColorEmoji/LICENSE"

log "installed $(ls "${FONTS}" | wc -l | tr -d ' ') fonts in build/root/System/Library/Fonts ($(du -sh "${FONTS}" | cut -f1))"
