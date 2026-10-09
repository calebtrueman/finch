#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Run a command holding the VM lock, so that several people (or agents)
# building ramdisks and booting the QEMU VM don't trip over each other.
#
#   tools/vm/with-vm-lock.sh tools/vm/mkramdisk.sh
#   tools/vm/with-vm-lock.sh sh -c 'tools/vm/mkramdisk.sh && expect tools/vm/smoke.exp "finch-foo-test | cksum"'
set -euo pipefail
lock=/tmp/finch-vm.lock
until mkdir "$lock" 2>/dev/null; do
    # a lock left by a process that has gone
    if [[ -f "$lock/pid" ]] && ! kill -0 "$(cat "$lock/pid")" 2>/dev/null; then
        rm -rf "$lock"
        continue
    fi
    sleep 5
done
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT
"$@"
