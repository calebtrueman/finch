# SPDX-License-Identifier: MIT OR Apache-2.0
# Build variants for make-based builds; see tools/variant.sh.
ifeq ($(FINCH_VARIANT),)
FINCH_ARCH := arm64e
FINCH_VARIANT_CFLAGS :=
V :=
else ifeq ($(FINCH_VARIANT),phone)
FINCH_ARCH := arm64
FINCH_VARIANT_CFLAGS := -DFINCH_LINUX_TSD=1
V := -phone
else
$(error unknown FINCH_VARIANT $(FINCH_VARIANT))
endif
