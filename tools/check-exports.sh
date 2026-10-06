#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Compare a Finch-built dylib's exports with Apple's original from the base
# ramdisk, and report missing symbols that something in the image imports.
#
#   tools/check-exports.sh /usr/lib/system/libsystem_platform.dylib
#
# Exit 0 if nothing imports a missing symbol, 1 otherwise.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
path="${1:?usage: check-exports.sh <path of dylib inside the image>}"
ours="${FINCH_ROOT}/build/root${path}"
base="${FINCH_ROOT}/third_party/darwin-vm/firmware/ramdisk.dmg"
image="${FINCH_ROOT}/build/vm/ramdisk.dmg"
[[ -f "${ours}" ]] || { echo "error: ${ours} not built" >&2; exit 2; }

tmp="$(mktemp -d)"
mnt="${tmp}/mnt"; mkdir "${mnt}"
cleanup() { hdiutil detach "${mnt}" >/dev/null 2>&1 || true; rm -rf "${tmp}"; }
trap cleanup EXIT

exports() { nm -gU -arch arm64e "$1" 2>/dev/null | awk '{print $NF}' | sort -u; }

hdiutil attach -readonly -nobrowse -mountpoint "${mnt}" "${base}" >/dev/null
exports "${mnt}${path}" > "${tmp}/apple"
hdiutil detach "${mnt}" >/dev/null
exports "${ours}" > "${tmp}/ours"
comm -23 "${tmp}/apple" "${tmp}/ours" > "${tmp}/missing"

install_name=$(otool -D "${ours}" | tail -1)
leaf=$(basename "${install_name}" .dylib)
echo "${path}: Apple exports $(wc -l < "${tmp}/apple" | tr -d ' '), ours $(wc -l < "${tmp}/ours" | tr -d ' '), missing $(wc -l < "${tmp}/missing" | tr -d ' ')"

# Who imports what from this library, across the current Finch image
# (falls back to the base image if the Finch image hasn't been built).
[[ -f "${image}" ]] || image="${base}"
hdiutil attach -readonly -nobrowse -mountpoint "${mnt}" -imagekey diskimage-class=CRawDiskImage "${image}" >/dev/null 2>&1 \
    || hdiutil attach -readonly -nobrowse -mountpoint "${mnt}" "${image}" >/dev/null
find "${mnt}" -type f \( -perm +111 -o -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null \
    | while IFS= read -r -d '' f; do
        file -b "$f" | grep -q Mach-O || continue
        # Count imports bound to this library directly, or through the
        # libSystem umbrella (which re-exports every /usr/lib/system dylib).
        nm -um "$f" 2>/dev/null | awk -v lib="(from ${leaf})" -v F="${f#"${mnt}"}" \
            'index($0, lib) || index($0, "(from libSystem)") { print $(NF-2), F }'
    done | sort -u > "${tmp}/imports"

awk 'NR == FNR { m[$1] = 1; next } ($1 in m)' "${tmp}/missing" "${tmp}/imports" > "${tmp}/needed"
if [[ -s "${tmp}/needed" ]]; then
    echo "missing symbols that are imported:"
    sed 's/^/  /' "${tmp}/needed"
    exit 1
fi
[[ -s "${tmp}/missing" ]] && echo "missing but unused: $(tr '\n' ' ' < "${tmp}/missing")"
exit 0
