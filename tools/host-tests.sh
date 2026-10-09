#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Run the host test suite: each comparison test against Apple's frameworks and
# against Finch's (build/root, through DYLD_FRAMEWORK_PATH), comparing all but
# the first line (which names the image used), and each Finch-only window-server
# test against its .expected file. Prints one line per test and a summary;
# exits non-zero if any differ.
#
#   tools/host-tests.sh [NAME...]     (NAME as in finch-NAME; default: all)
#   FINCH_TRIAL=dir  puts dir first in DYLD_FRAMEWORK_PATH (a trial AppKit, say)
#
# Build the tests first (make -C userland/tests). Run this script directly:
# perl, python and /bin/sh would lose DYLD_* to SIP.
set -uo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${FINCH_ROOT}"
# Finch draws in Classic, AppKit's Aqua-compatible theme, to compare with Apple's (docs/design/FIELDWORK.md).
export FINCH_THEME=Classic
B=build/userland
R=build/root/System/Library
# (frameworks nested in umbrellas are found by their own name, so their folders are listed too)
FW="${FINCH_TRIAL:+${FINCH_TRIAL}:}${R}/Frameworks:${R}/PrivateFrameworks:${R}/Frameworks/Quartz.framework/Frameworks"
FW="${FW}:${R}/Frameworks/CoreServices.framework/Versions/A/Frameworks"
SERVER=build/root/usr/libexec/finch-windowserver
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# name|arguments: comparison tests (arguments are relative to the repo root)
COMPARE=(
    "cf-test|" "foundation-test|" "intl-test|" "misc-test|" "data-test|" "collections-test|" "kvc-test|"
    "archive-test|" "predicate-test|" "measurement-test|" "bridge-test|" "streams-test|" "documents-test|"
    "files-test|" "xmlparser-test|" "cfnotify-test|" "l10n-test|" "uti-test|" "cg-test|" "imageio-test|"
    "ct-test|" "quartzcore-test|" "calayer-test|" "uifoundation-test|" "appkit-core-test|" "appkit-draw-test|"
    "appkit-containers-test|" "appkit-controls-test|${B}/controls-test.nib" "appkit-menu-test|${B}/menu-test.nib"
    "appkit-text-test|${B}/appkit-text-test.nib" "appkit-document-test|${B}" "nib-test|${B}/nib-test.nib"
    "appkit-layout-test|${B}" "appkit-bindings-test|${B}/appkit-bindings-test.nib" "appkit-panels-test|"
    "textkit2-test|" "appkit-tables-test|" "appkit-containers2-test|" "appkit-controls2-test|" "imagekit-test|"
    "coreservices-test|build/coreservices-test" "security-test|" "rtf-test|" "filecoordinator-test|" "textfinder-test|" "ruler-test|" "textblock-test|" "combine-test|" "swift-overlay-test|" "swift-runtime-test|"
)
# Finch-only window-server tests and their expected output
EXPECT=(window controls-window menu-window text-window panels-window tables-window)

want() {
    [[ $# -eq 0 || -z "${SELECTED}" ]] && return 0
    [[ " ${SELECTED} " == *" $1 "* ]]
}
SELECTED="$*"
pass=0
fail=0
skip=0
report() {
    printf '%-34s %s\n' "$1" "$2"
}

for entry in "${COMPARE[@]}"; do
    name="${entry%%|*}"
    args="${entry#*|}"
    want "${name}" || continue
    bin="${B}/finch-${name}"
    if [[ ! -x "${bin}" ]]; then
        report "${name}" "not built"
        skip=$((skip + 1))
        continue
    fi
    # shellcheck disable=SC2086
    "${bin}" ${args} > "${TMP}/apple" 2>/dev/null
    # shellcheck disable=SC2086
    DYLD_FRAMEWORK_PATH="${FW}" DYLD_LIBRARY_PATH=build/root/usr/lib/swift FINCH_FONT_DIRS="${R}/Fonts" "${bin}" ${args} > "${TMP}/finch" 2>/dev/null
    n=$(tail -n +2 "${TMP}/apple" | wc -l | tr -d ' ')
    d=$(diff <(tail -n +2 "${TMP}/apple") <(tail -n +2 "${TMP}/finch") | grep -c '^[<>]')
    if [[ "${n}" -eq 0 ]]; then
        report "${name}" "no output from Apple's run"
        fail=$((fail + 1))
    elif [[ "${d}" -eq 0 ]]; then
        report "${name}" "ok (${n} lines)"
        pass=$((pass + 1))
    else
        report "${name}" "DIFFERS (${d} lines of ${n})"
        fail=$((fail + 1))
    fi
done

for name in "${EXPECT[@]}"; do
    want "appkit-${name}-test" || continue
    bin="${B}/finch-appkit-${name}-test"
    expected="userland/tests/appkit-${name}-test.expected"
    if [[ ! -x "${bin}" || ! -f "${expected}" ]]; then
        report "appkit-${name}-test" "not built"
        skip=$((skip + 1))
        continue
    fi
    DYLD_FRAMEWORK_PATH="${FW}" FINCH_FONT_DIRS="${R}/Fonts" "${bin}" "${SERVER}" > "${TMP}/finch" 2>/dev/null
    d=$(diff "${TMP}/finch" "${expected}" | grep -c '^[<>]')
    if [[ "${d}" -eq 0 ]]; then
        report "appkit-${name}-test" "ok (expected)"
        pass=$((pass + 1))
    else
        report "appkit-${name}-test" "DIFFERS from expected (${d} lines)"
        fail=$((fail + 1))
    fi
done

if want hello-test; then
    DYLD_FRAMEWORK_PATH="${FW}" FINCH_FONT_DIRS="${R}/Fonts" "${B}/finch-app-test" "${SERVER}" \
        "${B}/apps/Hello.app/Contents/MacOS/Hello" "window:Hello, Finch" wait:1500 windows output sample:5,40,content \
        sample:180,16,titlebar click:222,68 type:Finch click:111,99 click:298,132 output sample:298,132,button cmd:q \
        output > "${TMP}/finch" 2>/dev/null
    if diff -q "${TMP}/finch" userland/tests/hello-test.expected > /dev/null; then
        report hello-test "ok (expected)"
        pass=$((pass + 1))
    else
        report hello-test "DIFFERS from expected"
        fail=$((fail + 1))
    fi
fi

echo "${pass} passed, ${fail} failed, ${skip} not built"
[[ "${fail}" -eq 0 ]]
