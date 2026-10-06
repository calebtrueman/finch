#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build the Finch kernel (Apple's XNU + kernel/patches) and link it with Apple's
# kexts from the installed KDK into a bootable kernel collection.
#
#   tools/build-kernel.sh            # build kernel + kernel collection
#   tools/build-kernel.sh --install  # ...and make it the darwin-vm boot KC
#
# Uses tools/darwin-xnu-build for toolchain bootstrapping (mig, ctf tools,
# libfirehose, headers). Its build tree lives in build/xnu-work (git-ignored).
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

: "${FINCH_VERSION:=0.0.1}"
: "${XNU_TAG:=xnu-12377.101.15}"
: "${MACOS_VERSION:=26.4}"           # darwin-xnu-build release key (selects dep tags)
: "${MACOS_BUILD:=25E253}"
: "${KDKROOT:=/Library/Developer/KDKs/KDK_26.4.1_25E253.kdk}"
: "${KERNEL_CONFIG:=DEVELOPMENT}"
: "${MACHINE_CONFIG:=T8132}"
: "${KC_MANIFEST:=kernelcache.release.mac16g}"  # Mac16,10 (M4 Mac mini)

WORK="${FINCH_ROOT}/build/xnu-work"
KC_OUT="${FINCH_ROOT}/build/kc"
VM_FW="${FINCH_ROOT}/third_party/darwin-vm/firmware"
config_lc=$(tr '[:upper:]' '[:lower:]' <<<"${KERNEL_CONFIG}")
machine_lc=$(tr '[:upper:]' '[:lower:]' <<<"${MACHINE_CONFIG}")
KERNEL_BIN="${WORK}/build/xnu.obj/kernel.${config_lc}.${machine_lc}"
KC_NAME="finch-${FINCH_VERSION}.${machine_lc}"

install=0
[[ "${1:-}" == "--install" ]] && install=1

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ -d "${KDKROOT}" ]] || die "KDK not found: ${KDKROOT} (install it from developer.apple.com)"

# Homebrew ahead of MacPorts; python3 must be >= 3.12 for XNU/QEMU build scripts.
export PATH="/opt/homebrew/opt/python@3.13/libexec/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

mkdir -p "${WORK}" "${KC_OUT}"
ln -sfn "${FINCH_ROOT}/tools/darwin-xnu-build/patches" "${WORK}/patches"

# 1. Source: pristine Apple tag + Finch patches.
if [[ ! -d "${WORK}/xnu" ]]; then
    log "Cloning ${XNU_TAG}"
    git clone -q --depth 1 --branch "${XNU_TAG}" \
        https://github.com/apple-oss-distributions/xnu.git "${WORK}/xnu"
fi
for p in "${FINCH_ROOT}"/kernel/patches/*.patch; do
    if git -C "${WORK}/xnu" apply --check "$p" 2>/dev/null; then
        log "Applying $(basename "$p")"
        git -C "${WORK}/xnu" apply "$p"
    elif git -C "${WORK}/xnu" apply --check --reverse "$p" 2>/dev/null; then
        :   # already applied
    else
        die "patch does not apply: $p"
    fi
done

# 2. Kernel. darwin-xnu-build skips the kernel if it exists, and make won't
#    re-stamp the version banner unless version.[co] is gone.
rm -f "${KERNEL_BIN}"
find "${WORK}/build/xnu.obj" -name 'version.[co]' -delete 2>/dev/null || true
log "Building XNU ${KERNEL_CONFIG} ${MACHINE_CONFIG} (log: build/xnu-work/build.log)"
(
    cd "${WORK}"
    KERNEL_BUILDER=finch \
    KERNEL_BUILD_OBJROOT="finch-${FINCH_VERSION}/${XNU_TAG}/${KERNEL_CONFIG}_ARM64_${MACHINE_CONFIG}" \
    MACOS_VERSION="${MACOS_VERSION}" KDKROOT="${KDKROOT}" \
    KERNEL_CONFIG="${KERNEL_CONFIG}" ARCH_CONFIG=ARM64 MACHINE_CONFIG="${MACHINE_CONFIG}" \
        /opt/homebrew/bin/bash "${FINCH_ROOT}/tools/darwin-xnu-build/build.sh" > build.log 2>&1
) || die "XNU build failed; see ${WORK}/build.log"
[[ -f "${KERNEL_BIN}" ]] || die "kernel not produced; see ${WORK}/build.log"
strings "${KERNEL_BIN}" | awk '/^Darwin Kernel Version/ && !p { print "    " $0; p = 1 }'

# 3. Kernel collection: KDK manifest minus kexts we can't link.
log "Linking kernel collection ${KC_NAME}.${config_lc}"
manifest="${KDKROOT}/System/Library/KernelCollections/${KC_MANIFEST}.manifest.plist"
excluded=$(grep -v '^\s*#' "${FINCH_ROOT}/boot/kc/excluded-kexts.txt" | sed '/^\s*$/d')
bundles=$(plutil -convert json "${manifest}" -o - | jq -r '.requiredIdentifiers[]' \
    | grep -vxF -e "${excluded}" | awk '{print "-b " $1}')
rm -f "${KC_OUT}/${KC_NAME}.${config_lc}"
# shellcheck disable=SC2086
kmutil create -n boot -s none -a arm64e -z \
    -B "${KC_OUT}/${KC_NAME}" -V "${config_lc}" \
    -r "${KDKROOT}/System/Library/Extensions" --build "${MACOS_BUILD}" \
    -k "${KERNEL_BIN}" -x ${bundles} > "${KC_OUT}/kmutil.log" 2>&1 \
    || die "kmutil failed; see ${KC_OUT}/kmutil.log"
log "Built ${KC_OUT}/${KC_NAME}.${config_lc}"

# 4. Optionally make it darwin-vm's boot KC.
if (( install )); then
    mkdir -p "${VM_FW}/kcs"
    if [[ -f "${VM_FW}/bootkc" && ! -L "${VM_FW}/bootkc" ]]; then
        mv "${VM_FW}/bootkc" "${VM_FW}/kcs/stock.release"
    fi
    cp "${KC_OUT}/${KC_NAME}.${config_lc}" "${VM_FW}/kcs/"
    ln -sfn "kcs/${KC_NAME}.${config_lc}" "${VM_FW}/bootkc"
    log "darwin-vm will boot ${KC_NAME}.${config_lc}  (run: expect tools/vm/smoke.exp)"
fi
