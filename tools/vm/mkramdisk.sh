#!/bin/bash
# Build build/vm/ramdisk.dmg + ramdisk.tc: darwin-vm's base ramdisk plus the
# Finch files listed in tools/vm/overlay.txt. No sudo needed; the base image
# (third_party/darwin-vm/firmware/ramdisk.dmg) is never modified.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FW="${FINCH_ROOT}/third_party/darwin-vm/firmware"
OUT="${FINCH_ROOT}/build/vm"
OVERLAY="${FINCH_ROOT}/tools/vm/overlay.txt"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[[ -f "${FW}/ramdisk.dmg" && -f "${FW}/all_hashes" ]] || die "run darwin-vm setup first (docs/DEV_VM.md)"

mkdir -p "${OUT}"
cp "${FW}/ramdisk.dmg" "${OUT}/ramdisk.dmg"
cp "${FW}/all_hashes" "${OUT}/all_hashes"

mnt="$(mktemp -d)"
hdiutil attach -owners off -nobrowse -mountpoint "${mnt}" "${OUT}/ramdisk.dmg" >/dev/null
trap 'hdiutil detach "${mnt}" >/dev/null; rmdir "${mnt}"' EXIT

grep -v '^\s*#' "${OVERLAY}" | sed '/^\s*$/d' | while read -r src dst; do
    [[ -f "${FINCH_ROOT}/${src}" ]] || die "missing ${src} (build it first)"
    mkdir -p "${mnt}$(dirname "${dst}")"
    cp "${FINCH_ROOT}/${src}" "${mnt}${dst}"
    if [[ -x "${FINCH_ROOT}/${src}" ]] && codesign -d "${mnt}${dst}" 2>/dev/null; then
        codesign -d -vvv "${mnt}${dst}" 2>&1 | grep -i '^CDHash=' | cut -d= -f2 >> "${OUT}/all_hashes"
    fi
    echo "  ${dst}"
done

sort -u -o "${OUT}/all_hashes" "${OUT}/all_hashes"
python3 "${FINCH_ROOT}/third_party/darwin-vm/build_tc.py" "${OUT}/all_hashes" "${OUT}/ramdisk.tc"
echo "built ${OUT}/ramdisk.dmg ($(wc -l < "${OUT}/all_hashes" | tr -d ' ') trusted hashes)"
