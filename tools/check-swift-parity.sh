#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Swift symbol parity: how many of the Swift symbols ($s…, plus the overlay
# magic symbols) an Apple image on the host exports does Finch's image of the
# same install name export?
#
#   tools/check-swift-parity.sh [-v] [install-name ...]
#
# With no names it checks every library in build/root/usr/lib/swift and the
# Swift parts of Foundation and AppKit. -v lists the missing (-) and extra (+)
# symbols, demangled. Apple's images come from the host's dyld shared cache.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${FINCH_ROOT}/build/root"
verbose=0
[[ "${1:-}" == "-v" ]] && { verbose=1; shift; }
if [[ $# -eq 0 ]]; then
    set -- $(cd "${ROOT}" && ls usr/lib/swift/*.dylib | sed 's|^|/|') \
        /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation \
        /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
fi
swiftsyms() {   # Swift exports of an image (excluding re-exported ones)
    dyld_info -arch arm64e -exports "$1" 2>/dev/null \
        | awk '/^ *0x/ {print $2}' | grep -E '^_\$s|^__swift_FORCE_LOAD|^_\$ld\$' | sort -u || true
}
tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
printf '%-58s %7s %7s %7s %7s\n' image apple finch missing extra
for name in "$@"; do
    swiftsyms "${name}" > "${tmp}/apple"
    if [[ -f "${ROOT}${name}" ]]; then swiftsyms "${ROOT}${name}" > "${tmp}/finch"; else : > "${tmp}/finch"; fi
    comm -23 "${tmp}/apple" "${tmp}/finch" > "${tmp}/missing"
    comm -13 "${tmp}/apple" "${tmp}/finch" > "${tmp}/extra"
    printf '%-58s %7d %7d %7d %7d\n' "${name}" "$(wc -l < "${tmp}/apple")" "$(wc -l < "${tmp}/finch")" \
        "$(wc -l < "${tmp}/missing")" "$(wc -l < "${tmp}/extra")"
    if [[ ${verbose} == 1 && -s "${tmp}/missing" ]]; then
        sed 's/^_//' "${tmp}/missing" | xcrun swift-demangle --simplified | sed 's/^/    - /'
    fi
    if [[ ${verbose} == 1 && -s "${tmp}/extra" ]]; then
        sed 's/^_//' "${tmp}/extra" | xcrun swift-demangle --simplified | sed 's/^/    + /'
    fi
done
