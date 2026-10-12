# SPDX-License-Identifier: MIT OR Apache-2.0
# Build variants (sourced by build scripts; userland/variant.mk is the make twin).
#
# FINCH_VARIANT unset: the Mac/VM build, arm64e, into build/root.
# FINCH_VARIANT=phone: Finch Phone (github.com/calebtrueman/finch-phone), which runs
#   this userland on a Linux kernel. Plain arm64, because the phone's CPUs have no
#   pointer authentication, and FINCH_LINUX_TSD, because Linux doesn't let user code
#   set TPIDRRO_EL0, so the thread's TSD base lives in TPIDR_EL0 (os/tsd.h).
#
# Sets FINCH_ARCH, FINCH_VARIANT_CFLAGS, variant_defs (bare -D names, for Xcode) and V,
# the suffix of the variant's build directories (build/root$V, build/obj$V, ...), so
# a variant never touches the Mac build's outputs.
case "${FINCH_VARIANT:-}" in
"") FINCH_ARCH=arm64e; variant_defs="" ;;
phone) FINCH_ARCH=arm64; variant_defs="FINCH_LINUX_TSD=1" ;;
*) echo "error: unknown FINCH_VARIANT ${FINCH_VARIANT}" >&2; exit 1 ;;
esac
FINCH_VARIANT_CFLAGS=""
for d in ${variant_defs}; do FINCH_VARIANT_CFLAGS+=" -D${d}"; done
V="${FINCH_VARIANT:+-${FINCH_VARIANT}}"
export FINCH_ARCH FINCH_VARIANT_CFLAGS
