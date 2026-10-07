# SPDX-License-Identifier: MIT OR Apache-2.0
# Judge libm-compare's disagreements (LIBM_DUMP file) against high-precision
# reference values from mpmath: for each case, each library's error in ulps
# of the true value. Prints per-function counts of who is closer and the
# worst error of each library.
#
#   python judge.py <dump file> [-v] [--check <coremath.txt>]   (needs mpmath)
#
# --check: exit 1 if any function Finch takes from CORE-MATH is more than
# half an ulp from the true value (it is correctly rounded).
import math
import sys
from collections import defaultdict

import mpmath as mp

mp.mp.prec = 256


def ulp_err(r, t, fl):
    """Error of double/float r against mpmath value t, in ulps of t."""
    if math.isnan(r):
        return 0.0 if t is None else math.inf
    if t is None:
        return math.inf
    if mp.isinf(t):
        return 0.0 if (math.isinf(r) and (r > 0) == (t > 0)) else math.inf
    if math.isinf(r):
        return math.inf
    mant = 24 if fl else 53
    emin = -126 if fl else -1022
    at = abs(t)
    e = int(mp.floor(mp.log(at, 2))) if at != 0 else emin
    e = max(e, emin)
    ulp = mp.mpf(2) ** (e - mant + 1)
    return float(abs(mp.mpf(r) - t) / ulp)


def real_fn(name):
    fl = name.endswith('f') and name not in ('erf',)
    base = name[:-1] if fl else name
    base = base.lstrip('_')
    f = {
        'acos': mp.acos, 'asin': mp.asin, 'atan': mp.atan, 'acosh': mp.acosh, 'asinh': mp.asinh,
        'atanh': mp.atanh, 'cbrt': mp.cbrt, 'cos': mp.cos, 'sin': mp.sin, 'tan': mp.tan, 'cosh': mp.cosh,
        'sinh': mp.sinh, 'tanh': mp.tanh, 'exp': mp.exp, 'exp2': lambda x: mp.mpf(2) ** x, 'expm1': mp.expm1,
        'log': mp.log, 'log10': mp.log10, 'log1p': mp.log1p, 'log2': lambda x: mp.log(x, 2), 'erf': mp.erf,
        'erfc': mp.erfc, 'tgamma': mp.gamma, 'lgamma': lambda x: mp.log(abs(mp.gamma(x))),
        'sinpi': mp.sinpi, 'cospi': mp.cospi, 'tanpi': lambda x: mp.sinpi(x) / mp.cospi(x),
        'exp10': lambda x: mp.mpf(10) ** x, 'j0': lambda x: mp.besselj(0, x), 'j1': lambda x: mp.besselj(1, x),
        'y0': lambda x: mp.bessely(0, x), 'y1': lambda x: mp.bessely(1, x),
        'atan2': mp.atan2, 'pow': lambda x, y: mp.power(x, y), 'hypot': mp.hypot,
    }.get(base)
    return f, fl


def complex_fn(name):
    return {
        'ctan': mp.tan, 'ctanh': mp.tanh, 'csqrt': mp.sqrt, 'csin': mp.sin, 'csinh': mp.sinh, 'ccos': mp.cos,
        'ccosh': mp.cosh, 'cexp': mp.exp, 'clog': mp.log, 'casin': mp.asin, 'casinh': mp.asinh,
        'cacos': mp.acos, 'cacosh': mp.acosh, 'catan': mp.atan, 'catanh': mp.atanh,
    }.get(name)


def evaluate(f, args):
    try:
        v = f(*args)
        if isinstance(v, mp.mpc):
            return v
        if mp.im(v) != 0:
            return None
        return mp.re(v)
    except (ValueError, ZeroDivisionError, OverflowError):
        return None


stats = defaultdict(lambda: {'n': 0, 'finch_better': 0, 'apple_better': 0, 'tie': 0,
                             'finch_max': 0.0, 'apple_max': 0.0, 'worse': []})

for line in open(sys.argv[1]):
    p = line.split()
    name = p[0]
    if p[1] == 'c':
        f = complex_fn(name)
        if f is None:
            continue
        zr, zi, ar, ai, br, bi = (float.fromhex(v) for v in p[2:8])
        # Exactly on an axis, mpmath can't see signed zeros: skip.
        if zr == 0 or zi == 0 or not all(map(math.isfinite, (zr, zi))):
            continue
        t = evaluate(f, (mp.mpc(zr, zi),))
        if t is None:
            continue
        ea = max(ulp_err(ar, mp.re(t), False), ulp_err(ai, mp.im(t), False))
        eb = max(ulp_err(br, mp.re(t), False), ulp_err(bi, mp.im(t), False))
        # Relative to the larger component (componentwise ulps punish a
        # tiny component that is negligible next to the other).
        mag = max(abs(mp.re(t)), abs(mp.im(t)))
        if mag != 0 and mp.isfinite(mag):
            e = int(mp.floor(mp.log(mag, 2)))
            u = mp.mpf(2) ** (e - 52)
            ea = float(max(abs(mp.mpf(ar) - mp.re(t)), abs(mp.mpf(ai) - mp.im(t))) / u) if math.isfinite(ar) and math.isfinite(ai) else math.inf
            eb = float(max(abs(mp.mpf(br) - mp.re(t)), abs(mp.mpf(bi) - mp.im(t))) / u) if math.isfinite(br) and math.isfinite(bi) else math.inf
    else:
        f, fl = real_fn(name)
        if f is None:
            continue
        n = int(p[1])
        x, y, a, b = (float.fromhex(v) for v in p[2:6])
        if not math.isfinite(x) or (n == 2 and not math.isfinite(y)):
            continue
        args = (mp.mpf(x),) if n == 1 else (mp.mpf(x), mp.mpf(y))
        t = evaluate(f, args)
        ea, eb = ulp_err(a, t, fl), ulp_err(b, t, fl)
    s = stats[name]
    s['n'] += 1
    if eb < ea - 0.5:
        s['finch_better'] += 1
    elif ea < eb - 0.5:
        s['apple_better'] += 1
        if len(s['worse']) < 3:
            s['worse'].append((line.strip(), round(ea, 2), round(eb, 2)))
    else:
        s['tie'] += 1
    s['finch_max'] = max(s['finch_max'], eb)
    s['apple_max'] = max(s['apple_max'], ea)

print(f"{'function':14} {'cases':>6} {'finch closer':>12} {'apple closer':>12} {'tie':>5} {'finch max':>10} {'apple max':>10}")
for name in sorted(stats, key=lambda k: -stats[k]['apple_better']):
    s = stats[name]
    print(f"{name:14} {s['n']:6} {s['finch_better']:12} {s['apple_better']:12} {s['tie']:5} {s['finch_max']:10.3g} {s['apple_max']:10.3g}")
failed = []
if '--check' in sys.argv:
    cm = open(sys.argv[sys.argv.index('--check') + 1]).read()
    cm = {w for line in cm.splitlines() if not line.startswith('#') for w in line.split()}
    for name, s in stats.items():
        base = name.lstrip('_')
        base = base[:-1] if base.endswith('f') and base[:-1] in cm else base
        if base in cm and s['finch_max'] > 0.5 + 1e-6:
            failed.append((name, s['finch_max']))
    for name, e in failed:
        print(f'FAIL {name}: {e:.3f} ulp from the true value (CORE-MATH is correctly rounded)')
    print(f'judge --check: {len(failed)} correctly-rounded functions out of bounds')
if '-v' in sys.argv:
    for name, s in stats.items():
        for w in s['worse']:
            print('apple closer:', w)
sys.exit(1 if failed else 0)
