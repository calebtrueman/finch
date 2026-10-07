#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# libsystem_m.dylib: Finch's math library. Apple's Libm source isn't
# published for current releases. The real elementary and gamma/error
# functions come from CORE-MATH (correctly rounded, MIT; coremath.txt); the
# rest of C99 (complex, Bessel, remainders, rounding...) from FreeBSD's msun
# (BSD-licensed). Both are pinned below. The Apple-specific interfaces (__sincos_stret, __sinpi, __exp10,
# _Float16 functions, simd vector functions and matrix inverses, the geometry
# predicates, fenv with Apple's fenv_t, and the classification helpers) are
# Finch code in this directory. Geometry predicates use Shewchuk's
# public-domain adaptive-precision predicates (pinned by checksum).
#
# long double is double on Apple arm64, so msun is built as for
# platforms with a 64-bit long double (LDBL_PREC 53): the *l functions are
# the double ones, made as linker aliases.
#
# Linked as Apple ships it: install name, version 3312.100.1, umbrella
# System, Apple's export list, and only libdyld and libcompiler_rt.
#
#   userland/libm/build.sh    -> build/root/usr/lib/system/libsystem_m.dylib
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="${FINCH_ROOT}/userland/libm"
MSUN_TAG=release/14.5.0
MSUN="${FINCH_ROOT}/build/src/msun"
PRED_URL=https://www.cs.cmu.edu/afs/cs/project/quake/public/code/predicates.c
PRED_SHA256=f8662c3f407d1c1c5dcd4dd49ea8b8ddd801a71827d65734206ddc3741792029
PRED="${FINCH_ROOT}/build/src/predicates/predicates.c"
CM_COMMIT=9ef800d2597afb49e5d0f35963160c0a18abbd06
CM="${FINCH_ROOT}/build/src/core-math"
OBJ="${FINCH_ROOT}/build/obj/libm"
OUT="${FINCH_ROOT}/build/root/usr/lib/system/libsystem_m.dylib"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="xcrun -sdk macosx clang"
log() { echo "==> $*"; }

if [[ "$(git -C "${MSUN}" describe --tags --exact-match 2>/dev/null || true)" != "${MSUN_TAG}" ]]; then
    log "fetching FreeBSD msun (${MSUN_TAG})"
    rm -rf "${MSUN}"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "${MSUN_TAG}" --filter=blob:none --sparse \
        https://github.com/freebsd/freebsd-src.git "${MSUN}"
    git -C "${MSUN}" sparse-checkout set lib/msun lib/libc/include lib/libc/arm
fi
if [[ "$(git -C "${CM}" rev-parse HEAD 2>/dev/null || true)" != "${CM_COMMIT}" ]]; then
    log "fetching CORE-MATH (${CM_COMMIT:0:12})"
    rm -rf "${CM}"
    git init -q "${CM}"
    git -C "${CM}" remote add origin https://gitlab.inria.fr/core-math/core-math.git
    git -C "${CM}" fetch -q --depth 1 origin "${CM_COMMIT}"
    git -C "${CM}" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
CM_FNS=$(grep -v '^#' "${HERE}/coremath.txt" | tr '\n' ' ')

# Finch fixes to msun (applied once; see each patch).
for p in "${HERE}"/patches/*.patch; do
    git -C "${MSUN}" apply -R --check "$p" 2>/dev/null || { log "applying $(basename "$p")"; git -C "${MSUN}" apply "$p"; }
done
if [[ "$(shasum -a 256 "${PRED}" 2>/dev/null | cut -c1-64)" != "${PRED_SHA256}" ]]; then
    log "fetching Shewchuk's predicates"
    mkdir -p "$(dirname "${PRED}")"
    curl -sfL -o "${PRED}" "${PRED_URL}"
    [[ "$(shasum -a 256 "${PRED}" | cut -c1-64)" == "${PRED_SHA256}" ]] || { echo "predicates.c checksum mismatch" >&2; exit 1; }
fi

# msun's source list for LDBL_PREC 53, from its Makefile: every
# COMMON_SRCS block outside the "LDBL_PREC != 53" section. Finch provides fenv
# and the classification helpers, fmin/fmax and nan (apple_math.c).
srcs=$(python3 -I - "${MSUN}/lib/msun/Makefile" <(echo "${CM_FNS}") <<'EOF'
import re, sys
lines = open(sys.argv[1]).read().split('\n')
out, depth, skip, cont = [], 0, [], False
for line in lines:
    s = line.strip()
    if s.startswith('.if'):
        skip.append('LDBL_PREC} != 53' in s or 'LDBL_PREC} == 64' in s or 'LDBL_PREC} == 113' in s)
        continue
    if s.startswith('.elif'):
        if skip: skip[-1] = 'LDBL_PREC} != 53' in s or 'LDBL_PREC} == 113' in s
        continue
    if s.startswith('.else'):
        if skip: skip[-1] = not skip[-1]
        continue
    if s.startswith('.endif'):
        if skip: skip.pop()
        continue
    if re.match(r'COMMON_SRCS\s*\+?=', s) or cont:
        if not any(skip) and not s.startswith('#'):
            out += re.findall(r'[\w]+\.c', s)
        cont = s.endswith('\\')
# msun files whose functions come from CORE-MATH instead (coremath.txt).
cm = {
    'acos': ['e_acos.c', 'e_acosf.c'], 'acosh': ['e_acosh.c', 'e_acoshf.c'], 'asin': ['e_asin.c', 'e_asinf.c'],
    'asinh': ['s_asinh.c', 's_asinhf.c'], 'atan': ['s_atan.c', 's_atanf.c'], 'atan2': ['e_atan2.c', 'e_atan2f.c'],
    'atanh': ['e_atanh.c', 'e_atanhf.c'], 'cbrt': ['s_cbrt.c', 's_cbrtf.c'], 'cos': ['s_cos.c', 's_cosf.c'],
    'cosh': ['e_cosh.c', 'e_coshf.c'], 'cospi': ['s_cospi.c', 's_cospif.c'], 'erf': ['s_erf.c', 's_erff.c'],
    'erfc': [], 'exp': ['e_exp.c', 'e_expf.c'], 'exp10': [], 'exp2': ['s_exp2.c', 's_exp2f.c'],
    'expm1': ['s_expm1.c', 's_expm1f.c'], 'hypot': ['e_hypot.c', 'e_hypotf.c'],
    'lgamma': ['e_lgamma.c', 'e_lgamma_r.c', 'e_lgammaf.c', 'e_lgammaf_r.c', 'e_gamma.c', 'e_gamma_r.c',
               'e_gammaf.c', 'e_gammaf_r.c'],
    'log': ['e_log.c', 'e_logf.c'], 'log10': ['e_log10.c', 'e_log10f.c'], 'log1p': ['s_log1p.c', 's_log1pf.c'],
    'log2': ['e_log2.c', 'e_log2f.c'], 'pow': ['e_pow.c', 'e_powf.c'], 'sin': ['s_sin.c', 's_sinf.c'],
    'sincos': ['s_sincos.c', 's_sincosf.c'], 'sinh': ['e_sinh.c', 'e_sinhf.c'], 'sinpi': ['s_sinpi.c', 's_sinpif.c'],
    'tan': ['s_tan.c', 's_tanf.c'], 'tanh': ['s_tanh.c', 's_tanhf.c'], 'tanpi': ['s_tanpi.c', 's_tanpif.c'],
    'tgamma': ['b_tgamma.c', 's_tgammaf.c'],
}
wanted = open(sys.argv[2]).read().split()
dropped = {f for fn in wanted for f in cm[fn]}
print(' '.join(sorted(set(out) - dropped - {'fenv.c', 's_isfinite.c', 's_isnan.c', 's_isnormal.c', 's_signbit.c',
                                            's_fmin.c', 's_fminf.c', 's_fmax.c', 's_fmaxf.c', 's_nan.c'})))
EOF
)

# msun keeps most sources in src/ and the 4.4BSD-derived ones in bsdsrc/.
srcpath() { [[ -f "${MSUN}/lib/msun/src/$1" ]] && echo "${MSUN}/lib/msun/src/$1" || echo "${MSUN}/lib/msun/bsdsrc/$1"; }

# Aliases: msun's __weak_reference(sym, alias) lines (made by the linker
# on Mach-O), plus Finch's own (aliases.txt).
mkdir -p "${OBJ}"
{
    for s in ${srcs}; do
        sed -nE 's/^__weak_reference\(([A-Za-z0-9_]+), *([A-Za-z0-9_]+)\);.*/_\1 _\2/p' "$(srcpath "${s}")"
    done
    { grep -v '^#' "${HERE}/aliases.txt" || true; } | sed '/^\s*$/d'
    # CORE-MATH: cr_F is F (and Fl), cr_Ff is Ff. lgamma, sinpi/cospi/tanpi,
    # exp10 and sincos are reached through Finch wrappers (apple_math.c);
    # their plain names still exist for msun's internal callers.
    for f in ${CM_FNS}; do
        echo "_cr_${f} _${f}"
        echo "_cr_${f}f _${f}f"
        grep -qx "_${f}l" "${HERE}/exports.txt" && echo "_cr_${f} _${f}l"
    done | grep -vE "^_cr_lgamma"
} | sort -u > "${OBJ}/aliases.txt"

flags=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -O2 -fno-builtin
       -fno-stack-protector -ffp-contract=off -fno-math-errno)
msun_flags=(-include "${HERE}/freebsd_compat.h" -I"${HERE}/include" -I"${MSUN}/lib/msun/src" -I"${MSUN}/lib/msun/bsdsrc"
            -I"${MSUN}/lib/libc/include" -I"${MSUN}/lib/libc/arm" -w)
objs=()
log "compiling msun ($(echo ${srcs} | wc -w | tr -d ' ') sources)"
for s in ${srcs}; do
    o="${OBJ}/msun_${s%.c}.o"
    ${CC} "${flags[@]}" "${msun_flags[@]}" -c "$(srcpath "${s}")" -o "${o}"
    objs+=("${o}")
done

log "compiling CORE-MATH ($(echo ${CM_FNS} | wc -w | tr -d ' ') functions, double and float)"
cm_flags=(-std=gnu11 -include "${HERE}/cm_hooks.h" -w)
for f in ${CM_FNS}; do
    extra=()
    [[ "${f}" == pow ]] && extra=(-DFINCH_CM_FALLBACK="__finch_msun_pow(x, y)")
    [[ "${f}" == atan2 ]] && extra=(-DFINCH_CM_FALLBACK="__finch_msun_atan2(y, x)")
    ${CC} "${flags[@]}" "${cm_flags[@]}" ${extra[@]+"${extra[@]}"} -c "${CM}/src/binary64/${f}/${f}.c" -o "${OBJ}/cm_${f}.o"
    ${CC} "${flags[@]}" "${cm_flags[@]}" -c "${CM}/src/binary32/${f}/${f}f.c" -o "${OBJ}/cm_${f}f.o"
    objs+=("${OBJ}/cm_${f}.o" "${OBJ}/cm_${f}f.o")
done
# msun's pow and atan2 under private names: CORE-MATH's last resort.
${CC} "${flags[@]}" "${msun_flags[@]}" -Dpow=__finch_msun_pow -c "$(srcpath e_pow.c)" -o "${OBJ}/msun_fallback_pow.o"
${CC} "${flags[@]}" "${msun_flags[@]}" -Datan2=__finch_msun_atan2 -c "$(srcpath e_atan2.c)" -o "${OBJ}/msun_fallback_atan2.o"
objs+=("${OBJ}/msun_fallback_pow.o" "${OBJ}/msun_fallback_atan2.o")

log "compiling Finch additions and predicates"
for f in "${HERE}"/*.c; do
    o="${OBJ}/finch_$(basename "${f%.c}").o"
    ${CC} "${flags[@]}" -Wall -Wextra -Werror -I"${HERE}" -c "${f}" -o "${o}"
    objs+=("${o}")
done
${CC} "${flags[@]}" -w -DNO_TIMER -Dmain=predicates_unused_main -c "${PRED}" -o "${OBJ}/predicates.o"
objs+=("${OBJ}/predicates.o")

log "linking libsystem_m.dylib"
mkdir -p "$(dirname "${OUT}")"
${CC} -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib -nostdlib \
    -install_name /usr/lib/system/libsystem_m.dylib -compatibility_version 1 -current_version 3312.100.1 \
    -umbrella System -Wl,-exported_symbols_list,"${HERE}/exports.txt" -Wl,-alias_list,"${OBJ}/aliases.txt" \
    -Wl,-dead_strip "${objs[@]}" -L"${SDKROOT}/usr/lib/system" -ldyld -lcompiler_rt \
    -o "${OUT}"
codesign -f -s - "${OUT}" 2>/dev/null

# Licence notices of the third-party code built in (docs/LICENSING.md).
# Shewchuk's predicates are public domain and need none.
log "collecting licence notices"
LICENSES="${FINCH_ROOT}/build/root/usr/share/finch/licenses"
cm_files=()
for f in ${CM_FNS}; do
    cm_files+=("${CM}/src/binary64/${f}/${f}.c" "${CM}/src/binary32/${f}/${f}f.c")
done
python3 -I "${FINCH_ROOT}/tools/collect-notices.py" "CORE-MATH (https://core-math.gitlabpages.inria.fr/), in libsystem_m" \
    "${LICENSES}/CORE-MATH/NOTICES.txt" "${cm_files[@]}"
msun_files=()
for s in ${srcs} e_pow.c e_atan2.c; do msun_files+=("$(srcpath "${s}")"); done
python3 -I "${FINCH_ROOT}/tools/collect-notices.py" "FreeBSD lib/msun (${MSUN_TAG}), in libsystem_m" \
    "${LICENSES}/FreeBSD-msun/NOTICES.txt" "${msun_files[@]}"
cp "${MSUN}/COPYRIGHT" "${LICENSES}/FreeBSD-msun/COPYRIGHT"
log "done: ${OUT#"${FINCH_ROOT}/"}"
