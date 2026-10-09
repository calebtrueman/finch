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
# An interrupted build can leave the previous image attached; copying over
# it then makes the APFS resize below fail. Detach it first.
stale=$(hdiutil info | awk -v img="${OUT}/ramdisk.dmg" '$1 == "image-path" { f = ($3 == img) } f && /^\/dev\/disk[0-9]+[ \t]/ { print $1; exit }')
[[ -n "${stale}" ]] && hdiutil detach -force "${stale}" >/dev/null
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
mkdir -p "${mnt}/private/tmp" "${mnt}"/private/var/{tmp,run,log,root,rw}
# /var/folders (per-user temp/cache dirs) can't be a tmpfs mount point (System
# Policy), so it's a link into the /private/var/tmp tmpfs; rc creates the target.
rm -rf "${mnt}/private/var/folders"
ln -s tmp/folders "${mnt}/private/var/folders"
# Nor can /var/db: it's a link into the /private/var/rw tmpfs. Writes through
# the link resolve to /private/var/rw/db, which no System Policy rule names.
rm -rf "${mnt}/private/var/db"
ln -s rw/db "${mnt}/private/var/db"

# A test user for per-user domains (docs/design/SERVICES.md): no password, so
# it's reachable only through su from root. Home directories live under
# /Users, a link into the /private/var/rw tmpfs (rc creates the target).
etc="${mnt}/private/etc"
if ! grep -q '^finchtest:' "${etc}/master.passwd"; then
    echo 'finchtest:*:501:20::0:0:Finch Test User:/Users/finchtest:/bin/zsh' >> "${etc}/master.passwd"
fi
rm -rf "${mnt}/Users"
ln -s private/var/rw/Users "${mnt}/Users"

# The base ramdisk ships only the root-only /etc/master.passwd. macOS also has
# the world-readable /etc/passwd (no password or expiry fields) that
# non-root processes' user lookups read; derive it, as pwd_mkdb would.
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
    rsync -a --exclude '*.tbd' --exclude '*.a' --exclude '*.dSYM' --exclude '/usr/include/' \
        --exclude '/usr/local/include/' "${ROOT}/" "${mnt}/"
    n=0
    while IFS= read -r -d '' f; do
        if is_macho "$f"; then add_hashes "${mnt}${f#"${ROOT}"}"; n=$((n + 1)); fi
    done < <(find "${ROOT}" -name '*.dSYM' -prune -o -type f -print0)
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

# 2b. Apps from this Mac's own macOS, to try them on Finch's frameworks:
#     FINCH_HOST_APPS="TextEdit Stickies" copies /System/Applications/<name>.app
#     (or Utilities/<name>.app) to /Applications in the image. They come from
#     the user's install at build time and stay in the local image; nothing of
#     Apple's is added to the repository.
for app in ${FINCH_HOST_APPS:-}; do
    src="/System/Applications/${app}.app"
    [[ -d "${src}" ]] || src="/System/Applications/Utilities/${app}.app"
    [[ -d "${src}" ]] || die "no ${app}.app in /System/Applications"
    mkdir -p "${mnt}/Applications"
    cp -R "${src}" "${mnt}/Applications/" && chmod -R u+w "${mnt}/Applications/${app}.app"
    while IFS= read -r -d '' f; do
        is_macho "$f" && add_hashes "$f"
    done < <(find "${mnt}/Applications/${app}.app" -type f -print0)
    echo "  /Applications/${app}.app (from this Mac)"
done

# 3. Every dylib our binaries need must exist in the image. Weak links are
#    allowed to be absent (libobjc's libobjc-env and libswiftCore, as on macOS).
missing=$( { find "${ROOT}" -type f -print0 2>/dev/null; } | while IFS= read -r -d '' f; do
    is_macho "$f" || continue
    otool -L "$f" 2>/dev/null | tail -n +2 | grep -v ', weak)$' | awk '{print $1}' | while read -r dep; do
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
    # The base image still holds closed Apple binaries that link libraries
    # Finch has replaced (CoreFoundation, ...) and need symbols Finch's don't
    # have yet. Nothing on the boot path uses them, so the builder's
    # "Referenced from" images are left out of the cache and the build is
    # retried. A Finch-built image with a missing symbol is a real error.
    exclude="${OUT}/dsc-exclude.txt"
    : > "${exclude}"
    finch_files="${OUT}/finch-files.txt"
    { (cd "${ROOT}" 2>/dev/null && find . -type f | sed 's|^\.||')
      grep -v '^\s*#' "${OVERLAY}" | sed '/^\s*$/d' | awk '{print $2}'; } | sort -u > "${finch_files}"
    for attempt in 1 2 3 4 5 6 7 8; do
        rm -rf "${mnt}/System/Library/dyld"
        python3 "${FINCH_ROOT}/tools/dsc/mkmanifest.py" "${mnt}" "${OUT}/dsc-manifest.json" "${exclude}" | sed 's/^/  dsc: /'
        if "${builder}" -dylib_cache "${mnt}" -dst_root "${mnt}" -json_manifest "${OUT}/dsc-manifest.json" \
            -print_cdhashes > "${OUT}/dsc-build.log" 2>&1; then
            break
        fi
        unresolved=$(sed -n 's/^ *Referenced from: //p' "${OUT}/dsc-build.log" | sort -u)
        [[ -n "${unresolved}" && ${attempt} -lt 8 ]] || die "shared cache build failed (see ${OUT}/dsc-build.log)"
        # A Finch-built image may be left out only if it still links a closed
        # library (it isn't open yet anyway; reported below).
        for img in $(comm -12 <(echo "${unresolved}") "${finch_files}"); do
            closed=$(otool -L "${mnt}${img}" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
                [[ "${dep}" == "${img}" ]] && continue
                real=$(cd "${mnt}" && python3 -c 'import os,sys; print(os.path.realpath("."+sys.argv[1])[1:])' "${dep}")
                grep -qx "${dep}" "${finch_files}" || grep -qx "/${real#*/}" "${finch_files}" || echo "${dep}"
            done)
            [[ -n "${closed}" ]] || die "Finch-built ${img} needs symbols Finch's libraries don't have (see ${OUT}/dsc-build.log)"
            echo "  dsc: warning: ${img} still links closed $(echo ${closed} | tr ' ' ',')"
        done
        echo "${unresolved}" >> "${exclude}"
        sort -u -o "${exclude}" "${exclude}"
        # They can't load against Finch's libraries, so they leave the image
        # too (as a missing file, a weak dependency on one, such as
        # libobjc's on libswiftCore, is fine).
        echo "${unresolved}" | while read -r img; do rm -f "${mnt}${img}"; done
    done
    [[ -s "${exclude}" ]] && echo "  dsc: removed $(wc -l < "${exclude}" | tr -d ' ') closed base-image binaries Finch's libraries can't satisfy yet (${exclude#"${FINCH_ROOT}/"})"
    # As on macOS since 11, dylibs in the cache aren't also on disk. dyld in
    # PID 1 scans for "roots" (on-disk dylibs overriding the cache) at boot;
    # finding them, every process would load from disk and patch the cache.
    # The map lists each cached dylib's install path. An install path that's
    # a symlink (libstdc++.6.dylib -> libstdc++.6.0.9.dylib) goes along with
    # its target: if the target stayed, dyld's realpath() of the install path
    # would name an uncached on-disk file, and dlopen(RTLD_NOLOAD) of it
    # recurses until the stack overflows.
    removed=0
    while read -r p; do
        if [[ -L "${mnt}${p}" ]]; then
            l="$(readlink "${mnt}${p}")"
            case "${l}" in /*) t="${mnt}${l}" ;; *) t="$(dirname "${mnt}${p}")/${l}" ;; esac
            [[ "${l}" != *..* && -f "${t}" && ! -L "${t}" ]] && rm -f "${t}"
            rm -f "${mnt}${p}"; removed=$((removed + 1))
        elif [[ -f "${mnt}${p}" ]]; then
            rm -f "${mnt}${p}"; removed=$((removed + 1))
        fi
    done < <(grep '^/' "${mnt}/System/Library/dyld/dyld_shared_cache_arm64e.map" | sort -u)
    echo "  dsc: removed ${removed} cached dylibs from disk"
    mv "${mnt}"/System/Library/dyld/*.map "${OUT}/" 2>/dev/null   # host-side debugging aid, kept out of the image
    sed -n 's/.* cdhash: \([0-9a-f]*\)$/\1/p' "${OUT}/dsc-build.log" >> "${OUT}/all_hashes"
    echo "  dsc: $(ls "${mnt}/System/Library/dyld" | wc -l | tr -d ' ') cache files, $(du -sh "${mnt}/System/Library/dyld" | cut -f1)"
fi

# 5. Finch-built binaries whose libraries aren't in the image (on disk or in
#    the shared cache): those still linking closed libraries the image had to
#    drop. tools/check-closed.py lists every closed link.
if [[ -f "${OUT}/dyld_shared_cache_arm64e.map" ]]; then
    broken=$(grep -v '^\s*#' "${OVERLAY}" | sed '/^\s*$/d' | awk '{print $2}' | cat - <(cd "${ROOT}" && find . -type f | sed 's|^\.||') \
        | sort -u | while read -r img; do
            [[ -f "${mnt}${img}" ]] && is_macho "${mnt}${img}" || continue
            otool -L "${mnt}${img}" 2>/dev/null | tail -n +2 | grep -v ', weak)$' | awk '{print $1}' | while read -r dep; do
                [[ "${dep}" == @* || -e "${mnt}${dep}" ]] && continue
                grep -qx "${dep}" "${OUT}/dyld_shared_cache_arm64e.map" || echo "${img} (${dep})"
            done
        done | sort -u)
    if [[ -n "${broken}" ]]; then
        echo "  warning: Finch-built binaries that can't load (a closed library they link isn't in the image):"
        printf '    %s\n' ${broken// /_}
    fi
fi

sort -u -o "${OUT}/all_hashes" "${OUT}/all_hashes"
python3 "${FINCH_ROOT}/third_party/darwin-vm/build_tc.py" "${OUT}/all_hashes" "${OUT}/ramdisk.tc"
echo "built ${OUT}/ramdisk.dmg ($(df -h "${mnt}" | awk 'NR==2{print $4}') free, $(wc -l < "${OUT}/all_hashes" | tr -d ' ') trusted hashes)"
