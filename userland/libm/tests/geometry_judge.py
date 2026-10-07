# SPDX-License-Identifier: MIT OR Apache-2.0
# Decide libm-compare's geometry-predicate disagreements (LIBM_DUMP lines
# "<predicate> <apple> <finch> <coordinates...>") with exact rational
# arithmetic (Python's standard library only). Exits 1 if Finch's sign is
# ever wrong.
#
#   python3 geometry_judge.py <dump file>
import sys
from collections import Counter
from fractions import Fraction


def det(m):
    if len(m) == 1:
        return m[0][0]
    return sum((-1) ** j * m[0][j] * det([r[:j] + r[j + 1:] for r in m[1:]]) for j in range(len(m)))


def sign(v):
    return (v > 0) - (v < 0)


def exact(fn, c):
    if fn.startswith('orient_p') and len(c) == 6:          # 2d points a, b, c
        a, b, p = c[0:2], c[2:4], c[4:6]
        return sign(det([[a[0] - p[0], a[1] - p[1]], [b[0] - p[0], b[1] - p[1]]]))
    if fn.startswith('orient_v') and len(c) == 4:          # 2d vectors x, y
        return sign(det([c[0:2], c[2:4]]))
    if fn.startswith('orient_v') and len(c) == 9:          # 3d vectors x, y, z
        return sign(det([c[0:3], c[3:6], c[6:9]]))
    if fn.startswith('orient_p') and len(c) == 12:         # 3d points a, b, c, d
        a, b, p, d = c[0:3], c[3:6], c[6:9], c[9:12]
        return sign(det([[q[k] - d[k] for k in range(3)] for q in (a, b, p)]))
    if fn.startswith('incircle'):                          # x, a, b, c
        x, pts = c[0:2], (c[2:4], c[4:6], c[6:8])
        rows = [[q[0] - x[0], q[1] - x[1], (q[0] - x[0]) ** 2 + (q[1] - x[1]) ** 2] for q in pts]
        return sign(det(rows))
    if fn.startswith('insphere'):                          # x, a, b, c, d
        x, pts = c[0:3], (c[3:6], c[6:9], c[9:12], c[12:15])
        rows = [[q[k] - x[k] for k in range(3)] + [sum((q[k] - x[k]) ** 2 for k in range(3))] for q in pts]
        return sign(det(rows))
    raise ValueError(fn)


tally, wrong = Counter(), 0
for line in open(sys.argv[1]):
    p = line.split()
    if not p or not (p[0].startswith('orient') or p[0].startswith('incircle') or p[0].startswith('insphere')):
        continue
    fn, apple, finch = p[0], float.fromhex(p[1]), float.fromhex(p[2])
    coords = [Fraction(float.fromhex(v)) for v in p[3:]]
    truth = exact(fn, coords)
    if sign(finch) == truth:
        tally[(fn, 'finch right')] += 1
    else:
        tally[(fn, 'FINCH WRONG')] += 1
        wrong += 1
for (fn, who), n in sorted(tally.items()):
    print(f'  {fn:14} {who}: {n}')
print(f'geometry_judge: {sum(tally.values())} disagreements with Apple, Finch wrong in {wrong}')
sys.exit(1 if wrong else 0)
