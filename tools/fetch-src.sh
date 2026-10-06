#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Clone the Apple open-source projects pinned in userland/projects.txt into
# build/src/<project>. Re-running is cheap: existing checkouts at the right tag
# are left alone.
#   tools/fetch-src.sh            # all projects
#   tools/fetch-src.sh file_cmds  # just one
set -euo pipefail

FINCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${FINCH_ROOT}/build/src"
mkdir -p "${SRC}"

grep -v '^\s*#' "${FINCH_ROOT}/userland/projects.txt" | sed '/^\s*$/d' | while read -r name tag; do
    if [[ $# -gt 0 && " $* " != *" ${name} "* ]]; then
        continue
    fi
    dir="${SRC}/${name}"
    if [[ -d "${dir}" ]]; then
        have=$(git -C "${dir}" describe --tags --exact-match 2>/dev/null || echo none)
        [[ "${have}" == "${tag}" ]] && continue
        echo "${name}: have ${have}, want ${tag}; re-cloning"
        rm -rf "${dir}"
    fi
    echo "fetching ${tag}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${tag}" \
        "https://github.com/apple-oss-distributions/${name}.git" "${dir}"
done
