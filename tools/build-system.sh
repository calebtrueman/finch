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

# Like oss, for command projects: the tools listed in userland/oss/<project>.deferred
# (userland/INVENTORY.md) may fail; anything else failing stops the build.
oss_cmds() {   # oss_cmds <project> <targets...>
    local out failed allowed f
    out=$(tools/build-oss.sh "$@" 2>&1)
    echo "${out}"
    failed=$(sed -n 's/^  failed in: \(.*\)  (see.*/\1/p' <<<"${out}")
    allowed=$(grep -v '^\s*#' "userland/oss/$1.deferred" 2>/dev/null)
    for f in ${failed}; do
        grep -qx "${f}" <<<"${allowed}" || { echo "error: $1: ${f} failed and isn't deferred" >&2; return 1; }
    done
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
    "syslog|oss syslog libsystem_asl syslogd util aslmanager newsyslog"
    "configd|oss configd libsystem_configuration"
    "dnssd|oss mDNSResponder"
    "libmacho|oss cctools"
    "libiconv|oss libiconv charset libiconv iconv mkesdb mkcsmapper iconv_modules"
    "libutil|oss libutil util"
    "libmd|oss libmd libmd"
    "OpenBSM|oss OpenBSM bsm.0"
    "ncurses|oss ncurses libncurses"
    "OpenPAM|oss OpenPAM OpenPAM"
    # (the other pam_modules need closed frameworks: OpenDirectory, Heimdal, LocalAuthentication)
    # ICU (libicucore + data), for CoreFoundation (docs/design/COREFOUNDATION.md)
    "ICU|oss ICU"
    "CoreFoundation|userland/CoreFoundation/build.sh"
    "IOKit|userland/IOKit/build.sh"
    # The Swift runtime (libobjc links it, as Apple's does)
    "swift|userland/swift/build.sh"
    "pam_modules|oss pam_modules rootok uwtmp self env group nologin sacl launchd"
    "pam|make -s -C userland/pam"
    "libsystem-finch|make -s -C userland/libsystem"
    "libm|make -s -C userland/libm"
    "corecrypto|make -s -C userland/corecrypto install"
    "trace|make -s -C userland/libsystem/trace install"
    "Libsystem|oss Libsystem Libsystem"
    "llvm-runtimes|tools/build-llvm-runtimes.sh"
    "objc4|oss objc4 objc-env objc"
    "dyld|oss dyld dyld libdyld"
    "libsysmon|make -s -C userland/libsysmon"
    # libdispatch's firehose server for finch-logd. Finch's PRODUCT_NAME override
    # names the archive libdispatch.a; move it out of the image tree.
    "firehose|oss libdispatch libfirehose_server && mkdir -p build/userland/lib && mv -f build/root/usr/lib/system/libdispatch.a build/userland/lib/libfirehose_server.a"
    "logd|make -s -C userland/logd"
    # Commands (userland/INVENTORY.md lists the deferred ones that don't build yet)
    "file_cmds|oss_cmds file_cmds executables"
    "shell_cmds|oss_cmds shell_cmds All_OSX"
    "text_cmds|oss_cmds text_cmds executables"
    "adv_cmds|oss_cmds adv_cmds Desktop"
    "system_cmds|oss_cmds system_cmds All_MacOSX"
    "bash|oss bash bash"
    "zsh|oss zsh"
    "bc|oss bc"
    # Finch's own, after the commands so they're what the image gets
    "sh|make -s -C userland/sh"
    "mount_tmpfs|make -s -C userland/mount_tmpfs"
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
