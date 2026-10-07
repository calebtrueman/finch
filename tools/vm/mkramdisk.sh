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
# Grow the image. It's raw APFS with no partition map, which `hdiutil resize`
# rejects, so extend the file and let APFS grow its container into the new
# space (no sudo needed for a user-attached image).
truncate -s "${RAMDISK_SIZE:-1g}" "${OUT}/ramdisk.dmg"
dev=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "${OUT}/ramdisk.dmg" | awk 'NR==1{print $1}')
diskutil apfs resizeContainer "${dev}" 0 >/dev/null || die "APFS resize failed"
hdiutil detach "${dev}" >/dev/null
cp "${FW}/all_hashes" "${OUT}/all_hashes"

mnt="$(mktemp -d)"
hdiutil attach -owners off -nobrowse -mountpoint "${mnt}" \
    -imagekey diskimage-class=CRawDiskImage "${OUT}/ramdisk.dmg" >/dev/null
trap 'hdiutil detach "${mnt}" >/dev/null; rmdir "${mnt}"' EXIT

# cdhash of every Mach-O slice in a file, for the trust cache.
add_hashes() {
    local a
    for a in $(lipo -archs "$1" 2>/dev/null); do
        codesign -a "$a" -d -vvv "$1" 2>&1 | grep -i '^CDHash=' | cut -d= -f2
    done >> "${OUT}/all_hashes"
}
is_macho() { file -b "$1" | grep -q '^Mach-O'; }

# 0. Mount points for the tmpfs the boot script lays over the read-only root.
mkdir -p "${mnt}/private/tmp" "${mnt}"/private/var/{tmp,run,log,root}

# The base ramdisk ships only the root-only /etc/master.passwd. macOS also has
# the world-readable /etc/passwd (no password or expiry fields) that
# non-root processes' user lookups read; derive it, as pwd_mkdb would.
etc="${mnt}/private/etc"
if [[ -f "${etc}/master.passwd" && ! -f "${etc}/passwd" ]]; then
    awk -F: 'BEGIN { OFS = ":" } /^#/ { print; next } NF >= 10 { print $1, "*", $3, $4, $8, $9, $10 }' \
        "${etc}/master.passwd" > "${etc}/passwd"
    chmod 644 "${etc}/passwd"
    echo "  /etc/passwd: derived from master.passwd"
fi

# 1. Apple OSS staging tree.
if [[ -d "${ROOT}" ]]; then
    # Runtime files only: link stubs (.tbd), static archives and headers are
    # build products for the host, not the OS.
    rsync -a --exclude '*.tbd' --exclude '*.a' --exclude '/usr/include/' \
        --exclude '/usr/local/include/' "${ROOT}/" "${mnt}/"
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

# 4. dyld shared cache, built by Finch from the image's own dylibs
#    (tools/dsc/build-builder.sh; docs/design/DYLD_CACHE.md). Each cache file
#    is code-signed; its cdhash goes in the trust cache like any binary's.
#    FINCH_DSC=0 skips it (dyld then loads every dylib from disk).
if [[ "${FINCH_DSC:-1}" != 0 ]]; then
    builder="${FINCH_ROOT}/build/tools/dyld_shared_cache_builder"
    [[ -x "${builder}" ]] || "${FINCH_ROOT}/tools/dsc/build-builder.sh" >/dev/null || die "cache builder build failed"
    rm -rf "${mnt}/System/Library/dyld"
    python3 "${FINCH_ROOT}/tools/dsc/mkmanifest.py" "${mnt}" "${OUT}/dsc-manifest.json" | sed 's/^/  dsc: /'
    "${builder}" -dylib_cache "${mnt}" -dst_root "${mnt}" -json_manifest "${OUT}/dsc-manifest.json" \
        -print_cdhashes > "${OUT}/dsc-build.log" 2>&1 || die "shared cache build failed (see ${OUT}/dsc-build.log)"
    # As on macOS since 11, dylibs in the cache aren't also on disk. dyld in
    # PID 1 scans for "roots" (on-disk dylibs overriding the cache) at boot;
    # finding them, every process would load from disk and patch the cache.
    # The map lists each cached dylib's install path.
    removed=0
    while read -r p; do
        if [[ -f "${mnt}${p}" && ! -L "${mnt}${p}" ]]; then rm -f "${mnt}${p}"; removed=$((removed + 1)); fi
    done < <(grep '^/' "${mnt}/System/Library/dyld/dyld_shared_cache_arm64e.map")
    echo "  dsc: removed ${removed} cached dylibs from disk"
    mv "${mnt}"/System/Library/dyld/*.map "${OUT}/" 2>/dev/null   # host-side debugging aid, kept out of the image
    sed -n 's/.* cdhash: \([0-9a-f]*\)$/\1/p' "${OUT}/dsc-build.log" >> "${OUT}/all_hashes"
    echo "  dsc: $(ls "${mnt}/System/Library/dyld" | wc -l | tr -d ' ') cache files, $(du -sh "${mnt}/System/Library/dyld" | cut -f1)"
fi

sort -u -o "${OUT}/all_hashes" "${OUT}/all_hashes"
python3 "${FINCH_ROOT}/third_party/darwin-vm/build_tc.py" "${OUT}/all_hashes" "${OUT}/ramdisk.tc"
echo "built ${OUT}/ramdisk.dmg ($(df -h "${mnt}" | awk 'NR==2{print $4}') free, $(wc -l < "${OUT}/all_hashes" | tr -d ' ') trusted hashes)"
