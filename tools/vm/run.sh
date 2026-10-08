#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Boot the emulated M4 (darwin-vm's qemu-sptm) with Finch's kernel collection
# and ramdisk.
#
# Environment:
#   FINCH_INIT=0     boot the base image's launchd instead of finch-init (PID 1 by
#                    default when build/vm has Finch's ramdisk; launchdsuffix=finch). Apple's launchd needs xpc SPI
#                    Finch's libxpc doesn't have (docs/design/XPC.md), so with a
#                    Finch image it stops at "Symbol not found".
#   BOOT_ARGS_EXTRA  extra boot-args to append
#   KC / RAMDISK / TC  override images (defaults: darwin-vm bootkc, build/vm ramdisk if built)
#   DEBUG=1          expose a GDB stub on :1234 and wait for the debugger
# Quit with Ctrl-A x.
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DVM="${FINCH_ROOT}/third_party/darwin-vm"
FW="${DVM}/firmware"
QEMU="${DVM}/qemu-sptm/build/qemu-system-aarch64"

if [[ -f "${FINCH_ROOT}/build/vm/ramdisk.dmg" ]]; then
    : "${FINCH_INIT:=1}"   # Finch's image: finch-init is PID 1
    : "${RAMDISK:=${FINCH_ROOT}/build/vm/ramdisk.dmg}"
    : "${TC:=${FINCH_ROOT}/build/vm/ramdisk.tc}"
fi
: "${KC:=${FW}/bootkc}"
: "${RAMDISK:=${FW}/ramdisk.dmg}"
: "${TC:=${FW}/ramdisk.tc}"

boot_args="rd=md0 serial=3 -v -noprogress wdt=-1 wlan-olyhal-abort"
[[ "${FINCH_INIT:-0}" == 1 ]] && boot_args+=" launchdsuffix=finch"
[[ -n "${BOOT_ARGS_EXTRA:-}" ]] && boot_args+=" ${BOOT_ARGS_EXTRA}"

args=(
    -M darwin
    -bootkc "${KC}" -dtree "${FW}/dtree" -tc "${TC}" -ramdisk "${RAMDISK}"
    -args "${boot_args}"
    -nographic -serial mon:stdio -m 8G
)
[[ -f "${FW}/sptm" ]] && args+=(-sptm "${FW}/sptm" -txm "${FW}/txm")
[[ "${DEBUG:-0}" == 1 ]] && args+=(-s -S)

trap 'stty sane 2>/dev/null || true' EXIT
"${QEMU}" "${args[@]}"
