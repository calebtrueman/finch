# libsystem_m: Finch's math library

Apple doesn't publish Libm for current releases (the last open Libm is a decade old),
so Finch builds `/usr/lib/system/libsystem_m.dylib` from open sources:

| Part | Source | License |
|---|---|---|
| Real elementary and special functions: `acos` … `tanh`, `exp*`, `log*`, `pow`, `hypot`, `cbrt`, `erf`/`erfc`, `lgamma`/`tgamma`, `sinpi`/`cospi`/`tanpi`, `exp10`, in double and float (`coremath.txt`) | [CORE-MATH](https://core-math.gitlabpages.inria.fr/), pinned commit | MIT |
| Everything else in C99/C23: complex functions, Bessel functions, `fmod`, `remainder`, `remquo`, `frexp`, rounding, `nextafter`, `lgamma_r` sign rules… | FreeBSD `lib/msun`, `release/14.5.0` | BSD-style |
| Geometry predicates (`simd_orient`, `simd_incircle`, `simd_insphere`) | Shewchuk's adaptive predicates (pinned by checksum), plus Finch's exact bignum fallback (`exact_predicates.c`) | public domain; MIT OR Apache-2.0 |
| Apple's own interfaces: `fenv` with Apple's `fenv_t`, `__fpclassify*` and friends, `__sinpi`, `__sincos_stret`, `_Float16` functions, simd vector functions, matrix inverses, `matrix_identity_*` | Finch (`apple_math.c`, `apple_simd.c`) | MIT OR Apache-2.0 |

`build.sh` fetches the pinned sources, applies Finch's patches (`patches/`), and links
the library as Apple ships it: the same 444 exports, version 3312.100.1, umbrella System,
and no dependencies beyond libdyld and libcompiler_rt (no libc).

## Accuracy

The real functions are correctly rounded (CORE-MATH). Apple's are not: on the
disagreements found by the test, Apple is up to 2.6 ulp off for `tan`, 5 ulp for `erfc`,
291 ulp for `tgamma` and far more for `lgamma` near its zeros. Complex and Bessel
functions are comparable to Apple's.

## Tests

`make test` runs `tests/libm-compare.c` against Apple's library on the host (8.9 million
checks) and judges disagreements:

- Exact operations, `_Float16` functions, classification, `fenv` and matrix inverses must
  match Apple.
- Geometry-predicate signs that differ from Apple's are decided with exact rational
  arithmetic (`tests/geometry_judge.py`). Every difference so far is Apple's: its float
  predicates and some extreme-range double cases are not exact. Finch's are, over the
  whole range.
- With `make venv` (mpmath), `tests/judge.py --check` verifies the CORE-MATH functions
  are within half an ulp of high-precision reference values.

## Where Finch differs from Apple, on purpose

Rule: standard C functions follow the C standard; Apple-private symbols match Apple.

- Complex special values follow C's Annex G where Apple's don't. For example,
  `cexp(x - 0i)` is `e^x - 0i`, `catanh(1 + 0i)` is `+inf + 0i`, and `csinh(+inf + inf i)`
  is `±inf + NaN i`. `ctanh(0 + NaN i)` follows C23 (`0 + NaN i`); Apple follows C11.
- Some complex results are more accurate: `csqrt`, `ctan` and `ctanh` return tiny
  nonzero components where Apple flushes them to zero.
- The vector functions are the scalar functions on each lane, so they keep the sign of
  zero (Apple's vector `sin(-0)` lane gives `+0`).
- `remquo` keeps the quotient's sign for huge quotients whose low bits are zero (Apple
  returns 0).
- Float and half geometry predicates return the signed overflow when the exact value is
  too large for the type (Apple returns NaN).

Kept for compatibility with Apple:

- The exported `__isnormal*` helpers are true for subnormals, as Apple's are. (`isnormal()`
  from `<math.h>` compiles inline and gives the C answer.)
- `nan(tag)` parses the tag as Apple does (base 0 with wraparound; any other character
  gives payload 0). `ilogb(0)` and `ilogb(NaN)` are `INT_MIN`. `fmin`/`fmax` are the
  arm64 `FMINNM`/`FMAXNM` instructions. `fesetround` returns an invalid mode as its
  failure value.

## Upstream fixes found while porting (not yet reported)

- FreeBSD msun `sinpi`/`cospi` get the sign wrong for `2^31 <= |x| < 2^52`: they reduce
  the integer part by `2^30` once, then cast to `uint32_t` (`patches/0001`).
- FreeBSD's `arm/_fpmath.h` picks big-endian word order unless `__VFP_FP__` or
  `__ARM_EABI__` is defined, so it's wrong for 64-bit-long-double little-endian targets
  (Finch uses its own `include/_fpmath.h`).
