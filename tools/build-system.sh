#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build Finch's system layer from source, in dependency order, into
# build/root: Apple's open-source libSystem projects, Finch's own libraries,
# the LLVM runtimes, libobjc and dyld. The kernel (tools/build-kernel.sh) and
# the SDK overlay (tools/mksdk.sh) come first. Then the image is built with
# tools/vm/mkramdisk.sh.
#
#   tools/build-system.sh            # everything
#   tools/build-system.sh libmalloc  # one step (names below)
#
# Stops at the first step that fails, and prints where its log is.
set -uo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${FINCH_ROOT}"

oss() {   # oss <project> <targets...>: build, then fail on any compile/link error
    local out
    out=$(tools/build-oss.sh "$@" 2>&1)
    echo "${out}"
    ! grep -q "failed in:" <<<"${out}" \
        && ! grep -q "linker command failed" "build/logs/$1.log"
}

# name | command
steps=(
    "sdk|tools/mksdk.sh"
    "crashreporter|make -s -C userland/CrashReporterClient"
    "libsyscall|oss libsyscall"
    "libplatform|oss libplatform"
    "libpthread|oss libpthread libsystem_pthread"
    "libpthread-dyld|oss libpthread 'libpthread dyld'"
    "libmalloc|oss libmalloc libsystem_malloc"
    "Libc|oss Libc libsystem_c.dylib"
    "libdarwin|oss Libc libsystem_darwin.dylib"
    "libc-dyld|oss Libc libc_dyld"
    "collections|oss Libc libsystem_collections"
    "libclosure|oss libclosure Blocks-dynamic"
    "libdispatch|oss libdispatch libdispatch"
    "Libinfo|oss Libinfo Libinfo"
    "libxpc|make -s -C userland/libxpc"
    "Libnotify|oss Libnotify libnotify notifyd notifyutil"
    "keymgr|oss keymgr libkeymgr.dylib"
    "removefile|oss removefile removefile"
    "copyfile|oss copyfile copyfile"
    "syslog|oss syslog libsystem_asl"
    "configd|oss configd libsystem_configuration"
    "dnssd|oss mDNSResponder"
    "libmacho|oss cctools"
    "libiconv|oss libiconv charset libiconv iconv mkesdb mkcsmapper iconv_modules"
    "libutil|oss libutil util"
    "OpenBSM|oss OpenBSM bsm.0"
    "ncurses|oss ncurses libncurses"
    "libsystem-finch|make -s -C userland/libsystem"
    "libm|make -s -C userland/libm"
    "corecrypto|make -s -C userland/corecrypto install"
    "trace|make -s -C userland/libsystem/trace install"
    "sh|make -s -C userland/sh"
    "mount_tmpfs|make -s -C userland/mount_tmpfs"
    "Libsystem|oss Libsystem Libsystem"
    "llvm-runtimes|tools/build-llvm-runtimes.sh"
    "objc4|oss objc4 objc-env objc"
    "dyld|oss dyld dyld libdyld"
)

only="${1:-}"
for s in "${steps[@]}"; do
    name="${s%%|*}" cmd="${s#*|}"
    [[ -n "${only}" && "${only}" != "${name}" ]] && continue
    echo "==> ${name}"
    if ! eval "${cmd}"; then
        echo "error: step '${name}' failed (logs in build/logs/)" >&2
        exit 1
    fi
done
echo "==> done; next: tools/vm/mkramdisk.sh"
