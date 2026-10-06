#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build build/vm/ramdisk.dmg + ramdisk.tc: darwin-vm's base ramdisk, plus the
# build/root staging tree (Apple OSS built by tools/build-oss.sh), plus the
# Finch files listed in tools/vm/overlay.txt. No sudo needed; the base image
# (third_party/darwin-vm/firmware/ramdisk.dmg) is never modified.
#
# Also checks that every dylib our binaries link against exists in the image.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FW="${FINCH_ROOT}/third_party/darwin-vm/firmware"
OUT="${FINCH_ROOT}/build/vm"
OVERLAY="${FINCH_ROOT}/tools/vm/overlay.txt"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ -f "${FW}/ramdisk.dmg" && -f "${FW}/all_hashes" ]] || die "run darwin-vm setup first (docs/DEV_VM.md)"

ROOT="${FINCH_ROOT}/build/root"

mkdir -p "${OUT}"
cp "${FW}/ramdisk.dmg" "${OUT}/ramdisk.dmg"
# Note: the base image is raw APFS (no partition map), which hdiutil can't
# resize; it has ~23 MB free. Growing it is a TODO once the overlay outgrows that.
cp "${FW}/all_hashes" "${OUT}/all_hashes"

mnt="$(mktemp -d)"
hdiutil attach -owners off -nobrowse -mountpoint "${mnt}" "${OUT}/ramdisk.dmg" >/dev/null
trap 'hdiutil detach "${mnt}" >/dev/null; rmdir "${mnt}"' EXIT

# cdhash of every Mach-O slice in a file, for the trust cache.
add_hashes() {
    local a
    for a in $(lipo -archs "$1" 2>/dev/null); do
        codesign -a "$a" -d -vvv "$1" 2>&1 | grep -i '^CDHash=' | cut -d= -f2
    done >> "${OUT}/all_hashes"
}
is_macho() { file -b "$1" | grep -q '^Mach-O'; }

# 1. Apple OSS staging tree.
if [[ -d "${ROOT}" ]]; then
    rsync -a "${ROOT}/" "${mnt}/"
    n=0
    while IFS= read -r -d '' f; do
        if is_macho "$f"; then add_hashes "${mnt}${f#"${ROOT}"}"; n=$((n + 1)); fi
    done < <(find "${ROOT}" -type f -print0)
    echo "  build/root: ${n} Mach-O files"
fi

# 2. Finch files from the overlay manifest.
grep -v '^\s*#' "${OVERLAY}" | sed '/^\s*$/d' | while read -r src dst; do
    [[ -f "${FINCH_ROOT}/${src}" ]] || die "missing ${src} (build it first)"
    mkdir -p "${mnt}$(dirname "${dst}")"
    cp "${FINCH_ROOT}/${src}" "${mnt}${dst}"
    is_macho "${mnt}${dst}" && add_hashes "${mnt}${dst}"
    echo "  ${dst}"
done

# 3. Every dylib our binaries need must exist in the image.
missing=$( { find "${ROOT}" -type f -print0 2>/dev/null; } | while IFS= read -r -d '' f; do
    is_macho "$f" || continue
    otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
        [[ "${dep}" == @* ]] && continue
        [[ -e "${mnt}${dep}" ]] || echo "${dep} (needed by ${f#"${ROOT}"})"
    done
done | sort -u -t' ' -k1,1)
if [[ -n "${missing}" ]]; then
    echo "  warning: missing dylibs in image:"
    printf '    %s\n' ${missing// /_}
fi

sort -u -o "${OUT}/all_hashes" "${OUT}/all_hashes"
python3 "${FINCH_ROOT}/third_party/darwin-vm/build_tc.py" "${OUT}/all_hashes" "${OUT}/ramdisk.tc"
echo "built ${OUT}/ramdisk.dmg ($(wc -l < "${OUT}/all_hashes" | tr -d ' ') trusted hashes)"
