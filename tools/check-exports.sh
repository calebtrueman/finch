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
[[ -f "${ours}" ]] || { echo "error: ${ours} not built" >&2; exit 2; }

tmp="$(mktemp -d)"
mnt="${tmp}/mnt"; mkdir "${mnt}"
cleanup() { hdiutil detach "${mnt}" >/dev/null 2>&1 || true; rm -rf "${tmp}"; }
trap cleanup EXIT

exports() { nm -gU -arch arm64e "$1" 2>/dev/null | awk '{print $NF}' | sort -u; }

# Identity: current version and umbrella must match Apple's too.
identity() {   # identity <dylib>
    otool -l -arch arm64e "$1" 2>/dev/null | awk '
        /cmd LC_ID_DYLIB/ { id = 1 } id && /current version/ { v = $3; id = 0 }
        /cmd LC_SUB_FRAMEWORK/ { sf = 1 } sf && /umbrella/ { u = $2; sf = 0 }
        END { printf "version %s umbrella %s", v, (u ? u : "-") }'
}

hdiutil attach -readonly -nobrowse -mountpoint "${mnt}" "${base}" >/dev/null
exports "${mnt}${path}" > "${tmp}/apple"
apple_id=$(identity "${mnt}${path}")
hdiutil detach "${mnt}" >/dev/null
ours_id=$(identity "${ours}")
[[ "${apple_id}" == "${ours_id}" ]] || echo "identity differs: Apple ${apple_id}, ours ${ours_id}"
exports "${ours}" > "${tmp}/ours"
comm -23 "${tmp}/apple" "${tmp}/ours" > "${tmp}/missing"

install_name=$(otool -D "${ours}" | tail -1)
leaf=$(basename "${install_name}" .dylib)
echo "${path}: Apple exports $(wc -l < "${tmp}/apple" | tr -d ' '), ours $(wc -l < "${tmp}/ours" | tr -d ' '), missing $(wc -l < "${tmp}/missing" | tr -d ' ')"

# Who imports what from this library: every Mach-O in Apple's base image
# (the built image keeps cached dylibs only inside the shared cache, where
# they can't be scanned) plus everything Finch builds (build/root).
scan() {   # scan <root>
    find "$1" -type f \( -perm +111 -o -name '*.dylib' -o -name '*.so' \) -print0 2>/dev/null \
        | while IFS= read -r -d '' f; do
            file -b "$f" | grep -q Mach-O || continue
            # Count imports bound to this library directly, or through the
            # libSystem umbrella (which re-exports every /usr/lib/system dylib).
            nm -um "$f" 2>/dev/null | awk -v lib="(from ${leaf})" -v F="${f#"$1"}" \
                'index($0, lib) || index($0, "(from libSystem)") { print $(NF-2), F }'
        done
}
hdiutil attach -readonly -nobrowse -mountpoint "${mnt}" "${base}" >/dev/null
{ scan "${mnt}"; scan "${FINCH_ROOT}/build/root"; } | sort -u > "${tmp}/imports"

awk 'NR == FNR { m[$1] = 1; next } ($1 in m)' "${tmp}/missing" "${tmp}/imports" > "${tmp}/needed"
if [[ -s "${tmp}/needed" ]]; then
    echo "missing symbols that are imported:"
    sed 's/^/  /' "${tmp}/needed"
    exit 1
fi
[[ -s "${tmp}/missing" ]] && echo "missing but unused: $(tr '\n' ' ' < "${tmp}/missing")"
exit 0
