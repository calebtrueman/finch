#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Copy Finch's additions into the OpenBSM checkout (bsm_audit.c includes the
# file; userland/patches/OpenBSM/0001).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cp "${here}/OpenBSM/finch_compat.c" openbsm/libbsm/finch_compat.c
