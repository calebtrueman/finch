#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Generate every Finch brand asset from geometry defined here.

The mark, the wordmark and the tagline lettering are all constructed (circles,
tangent lines, monoline strokes), so the brand needs no font and no licence beyond
Finch's own. SVGs are the masters; PNGs, icons, the social card, the brand sheet,
the boot splash and finch-init's console art are rendered from them.

Usage:  tools/mkbrand.py [branding-dir]        (default: branding)
Needs:  rsvg-convert (librsvg), magick (ImageMagick) for favicon.ico,
        iconutil (macOS) for Finch.icns. Python 3 standard library only.
"""
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'branding'))
BANNER_H = os.path.join(ROOT, 'userland', 'finch-init', 'banner_art.h')

# Palette (branding/BRAND.md).
INK = '#16181B'      # wordmark, mark, dark backgrounds
PAPER = '#F6F3EC'    # light backgrounds, mark on dark
SEED = '#E9A23B'     # the beak and the dot of the i; never text
STONE = '#686C71'    # secondary text on Paper
MIST = '#A4A7AC'     # secondary text on Ink
LINE = '#2A2D31'     # hairlines / tracks on Ink

TAGLINE = 'AN OPEN OS FOR APPLE SILICON'


def f(p):
    return f'{p[0]:.2f} {p[1]:.2f}'


# ---------------------------------------------------------------------------
# The mark: a Darwin's finch. Head and body are one circle; the tail is the
# wedge of its two tangents to a point; the stout seed-cracking beak sits off
# the head behind a small gap. Coordinates are in a 256 grid.

def mark_geometry():
    cx, cy, r = 0.0, 0.0, 74.0
    P = (cx - 118, cy + 96)                      # tail tip
    dx, dy = P[0] - cx, P[1] - cy
    d, a = math.hypot(dx, dy), math.atan2(dy, dx)
    b = math.acos(r / d)
    t1 = (cx + r * math.cos(a + b), cy + r * math.sin(a + b))
    t2 = (cx + r * math.cos(a - b), cy + r * math.sin(a - b))
    body = f'M{f(t1)} L{f(P)} L{f(t2)} A{r} {r} 0 1 0 {f(t1)} Z'

    R = r + 7                                     # gap between head and beak
    A1, A2 = math.radians(-44), math.radians(6)
    b1 = (cx + R * math.cos(A1), cy + R * math.sin(A1))
    b2 = (cx + R * math.cos(A2), cy + R * math.sin(A2))
    T = (cx + r + 46, cy - 8)                    # beak tip
    ctl = ((b1[0] + T[0]) / 2 + 5, (b1[1] + T[1]) / 2 - 7)
    beak = f'M{f(b1)} Q{f(ctl)} {f(T)} L{f(b2)} A{R} {R} 0 0 0 {f(b1)} Z'

    eye = (cx + r * 0.40, cy - r * 0.36, r * 0.125)
    x0, y0 = P[0], cy - r
    x1, y1 = T[0], P[1]
    return dict(body=body, beak=beak, eye=eye, bbox=(x0, y0, x1, y1))


MARK = mark_geometry()


def mark_group(x, y, h, ink, seed, cutout=None, uid='m'):
    """The mark scaled so its height is h, top-left at (x, y).

    The eye is a hole (mask) so the mark works on any background. With
    cutout set, the eye is painted in that colour instead (for raster use)."""
    x0, y0, x1, y1 = MARK['bbox']
    s = h / (y1 - y0)
    ex, ey, er = MARK['eye']
    tr = f'translate({x - x0 * s:.3f} {y - y0 * s:.3f}) scale({s:.5f})'
    return (f'<g transform="{tr}">'
            f'<mask id="{uid}" maskUnits="userSpaceOnUse" x="-200" y="-200" width="400" height="400">'
            f'<rect x="-200" y="-200" width="400" height="400" fill="#fff"/>'
            f'<circle cx="{ex:.2f}" cy="{ey:.2f}" r="{er:.2f}" fill="#000"/></mask>'
            f'<path d="{MARK["body"]}" fill="{ink}" mask="url(#{uid})"/>'
            f'<path d="{MARK["beak"]}" fill="{seed}"/></g>')


def mark_size(h):
    x0, y0, x1, y1 = MARK['bbox']
    return (x1 - x0) * h / (y1 - y0), h


# ---------------------------------------------------------------------------
# Lettering. Monoline strokes on a grid: y=0 is the top of the ascender
# (lowercase) or cap height (capitals); the baseline is y=140 (lowercase) or
# y=100 (capitals).

SW = 22                         # wordmark stroke
XH = 40                         # x-height line (outer edge)


def lower_glyphs():
    h = SW / 2
    # Arch of n and h: centreline top sits half a stroke under the x-height.
    def arch(x):
        rr = 44
        cy = XH + h + rr
        return f'M{x} {cy} A{rr} {rr} 0 0 1 {x + 2 * rr} {cy} V140'
    g = {}
    # f: stem, hook to the right, crossbar.
    g['f'] = (f'M{h} 140 V{h + 30} A30 30 0 0 1 {h + 30} {h} H{h + 46} '
              f'M0 {XH + h} H{h + 40}', 60, [])
    g['i'] = (f'M{h} 140 V{XH}', SW, [(h, h + 2, h + 3)])
    g['n'] = (f'M{h} 140 V{XH} ' + arch(h), h + 88 + h, [])
    rc = 47
    ccx, ccy = h + rc, XH + h + rc - 2
    a0, a1 = math.radians(-42), math.radians(42)
    g['c'] = (f'M{ccx + rc * math.cos(a0):.2f} {ccy + rc * math.sin(a0):.2f} '
              f'A{rc} {rc} 0 1 0 {ccx + rc * math.cos(a1):.2f} {ccy + rc * math.sin(a1):.2f}',
              ccx + rc * math.cos(a0) + 2, [])
    g['h'] = (f'M{h} 140 V0 ' + arch(h), h + 88 + h, [])
    return g


LOWER = lower_glyphs()
KERN = {('f', 'i'): -4, ('i', 'n'): 0, ('n', 'c'): 0, ('c', 'h'): 2}
TRACK = 20


def wordmark_paths(word='finch'):
    """Returns (strokes, dots, width) in the 0..140 grid."""
    x, strokes, dots = 0.0, [], []
    for i, ch in enumerate(word):
        d, w, ds = LOWER[ch]
        strokes.append(f'<path transform="translate({x:.2f} 0)" d="{d}"/>')
        dots += [(x + dx, dy, dr) for dx, dy, dr in ds]
        x += w + TRACK
        if i + 1 < len(word):
            x += KERN.get((ch, word[i + 1]), 0)
    return strokes, dots, x - TRACK


def wordmark_group(x, y, h, ink, seed):
    """Wordmark with ascender-to-baseline height h at (x, y)."""
    s = h / 140
    strokes, dots, _ = wordmark_paths()
    body = ''.join(strokes)
    dd = ''.join(f'<circle cx="{dx:.2f}" cy="{dy:.2f}" r="{dr:.2f}" fill="{seed}"/>'
                 for dx, dy, dr in dots)
    return (f'<g transform="translate({x:.3f} {y:.3f}) scale({s:.5f})">'
            f'<g fill="none" stroke="{ink}" stroke-width="{SW}" stroke-linejoin="round">{body}</g>'
            f'{dd}</g>')


def wordmark_width(h):
    return wordmark_paths()[2] * h / 140


CAPS = {
    'A': ('M0 100 L40 0 L80 100 M15 64 H65', 80),
    'C': (None, 92),
    'E': ('M58 0 H0 V100 H58 M0 50 H50', 58),
    'F': ('M58 0 H0 V100 M0 50 H50', 54),
    'I': ('M0 0 V100', 0),
    'L': ('M0 0 V100 H54', 54),
    'N': ('M0 100 V0 L72 100 V0', 72),
    'O': ('M50 0 A50 50 0 1 0 50 100 A50 50 0 1 0 50 0 Z', 100),
    'P': ('M0 100 V0 H34 A27 27 0 0 1 34 54 H0', 61),
    'R': ('M0 100 V0 H34 A27 27 0 0 1 34 54 H0 M30 54 L64 100', 64),
    'S': (None, 62),
    'B': ('M0 100 V0 H32 A25 25 0 0 1 32 50 H0 M32 50 A25 25 0 0 1 32 100 H0', 59),
    'D': ('M0 0 V100 H30 A50 50 0 0 0 30 0 Z', 80),
    'G': (None, 94),
    'K': ('M0 0 V100 M60 0 L0 62 M22 40 L64 100', 64),
    'M': ('M0 100 V0 L44 72 L88 0 V100', 88),
    'T': ('M0 0 H64 M32 0 V100', 64),
    'U': ('M0 0 V64 A34 34 0 0 0 68 64 V0', 68),
    'W': ('M0 0 L24 100 L52 22 L80 100 L104 0', 104),
    'Y': ('M0 0 L34 50 L68 0 M34 50 V100', 68),
}


def _cap_c():
    r, c = 50, (50, 50)
    a0, a1 = math.radians(-40), math.radians(40)
    return (f'M{c[0] + r * math.cos(a0):.2f} {c[1] + r * math.sin(a0):.2f} '
            f'A{r} {r} 0 1 0 {c[0] + r * math.cos(a1):.2f} {c[1] + r * math.sin(a1):.2f}')


def _cap_s():
    # Two stacked bowls; the upper one a little narrower, as in most grotesques.
    ru, rl = 26.0, 28.0
    cu, cl = (31.0, 25.0), (31.0, 100 - rl + 3)
    au = math.radians(-35)
    al = math.radians(150)
    start = (cu[0] + ru * math.cos(au), cu[1] + ru * math.sin(au))
    mid = (31.0, 50.0)
    end = (cl[0] + rl * math.cos(al), cl[1] + rl * math.sin(al))
    return (f'M{f(start)} A{ru} {25} 0 1 0 {f(mid)} '
            f'A{rl} {25} 0 1 1 {f(end)}')


CAPS['C'] = (_cap_c(), 92)
CAPS['S'] = (_cap_s(), 62)
CAPS['G'] = (_cap_c() + ' V56 H58', 94)     # C, then the spur up and in


def caps_text(text, x, y, h, color, weight=9, track=0.42, anchor='start'):
    """Constructed capitals, cap height h, baseline at y + h."""
    s = h / 100
    adv, parts, cx = track * 100, [], 0.0
    for ch in text:
        if ch == ' ':
            cx += 44
            continue
        d, w = CAPS[ch]
        parts.append(f'<path transform="translate({cx:.2f} 0)" d="{d}"/>')
        cx += w + adv
    width = (cx - adv) * s
    if anchor == 'middle':
        x -= width / 2
    elif anchor == 'end':
        x -= width
    return (f'<g transform="translate({x:.3f} {y:.3f}) scale({s:.5f})" fill="none" '
            f'stroke="{color}" stroke-width="{weight}" stroke-linejoin="round">{"".join(parts)}</g>'), width


def caps_width(text, h, track=0.42):
    return caps_text(text, 0, 0, h, '#000', track=track)[1]


# ---------------------------------------------------------------------------
# Documents.

def svg_doc(w, h, body, bg=None, title=None):
    t = f'<title>{title}</title>' if title else ''
    b = f'<rect width="{w}" height="{h}" fill="{bg}"/>' if bg else ''
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:g} {h:g}" '
            f'width="{w:g}" height="{h:g}">{t}{b}{body}</svg>\n')


def theme(dark):
    return dict(ink=PAPER if dark else INK, seed=SEED, sub=MIST if dark else STONE,
                bg=INK if dark else PAPER)


def symbol_svg(dark=False, mono=False, size=256, pad=20):
    t = theme(dark)
    mh = size - 2 * pad
    mw, _ = mark_size(mh)
    if mw > size - 2 * pad:
        mh *= (size - 2 * pad) / mw
        mw = size - 2 * pad
    seed = t['ink'] if mono else t['seed']
    g = mark_group((size - mw) / 2, (size - mh) / 2, mh, t['ink'], seed)
    return svg_doc(size, size, g, title='Finch')


def logo_svg(dark=False, mono=False, bg=False):
    """Horizontal lockup: mark, wordmark, tagline under the wordmark."""
    t = theme(dark)
    seed = t['ink'] if mono else t['seed']
    H = 140                                       # wordmark height
    mh = 152
    mw, _ = mark_size(mh)
    pad, gap = 24, 34
    ww = wordmark_width(H)
    th = 100 * ww / caps_width(TAGLINE, 100)    # tagline spans the wordmark
    W = pad + mw + gap + ww + pad
    wy = pad + (mh - H) / 2 - 16
    body = mark_group(pad, pad, mh, t['ink'], seed)
    body += wordmark_group(pad + mw + gap, wy, H, t['ink'], seed)
    tg, _ = caps_text(TAGLINE, pad + mw + gap, wy + H + 26, th, t['sub'], weight=11)
    body += tg
    Hh = max(pad + mh + pad, wy + H + 26 + th + pad)
    return svg_doc(W, Hh, body, bg=t['bg'] if bg else None, title='Finch')


def stacked_svg(dark=False, bg=False):
    t = theme(dark)
    mh = 220
    mw, _ = mark_size(mh)
    H = 150
    ww = wordmark_width(H)
    W = max(mw, ww) + 120
    y = 60
    body = mark_group((W - mw) / 2, y, mh, t['ink'], t['seed'])
    y += mh + 56
    body += wordmark_group((W - ww) / 2, y, H, t['ink'], t['seed'])
    y += H + 42
    tg, _ = caps_text(TAGLINE, W / 2, y, 15, t['sub'], weight=11, anchor='middle')
    body += tg
    return svg_doc(W, y + 15 + 60, body, bg=t['bg'] if bg else None, title='Finch')


def wordmark_svg(dark=False):
    t = theme(dark)
    H, pad = 140, 20
    ww = wordmark_width(H)
    return svg_doc(ww + 2 * pad, H + 2 * pad,
                   wordmark_group(pad, pad, H, t['ink'], t['seed']), title='finch')


def icon_svg(dark=False, size=1024, small=False):
    """App icon: the mark on a Paper (or Ink) tile with macOS grid margins.

    small: a tighter tile and a bigger mark for 16 and 32 px renders."""
    t = theme(dark)
    m = size * (40 if small else 100) / 1024
    side = size - 2 * m
    rad = side * 0.225
    tile = (f'<rect x="{m}" y="{m}" width="{side}" height="{side}" rx="{rad:.1f}" '
            f'fill="{t["bg"]}"/>')
    if not dark:
        tile += (f'<rect x="{m + 1}" y="{m + 1}" width="{side - 2}" height="{side - 2}" '
                 f'rx="{rad - 1:.1f}" fill="none" stroke="#000" stroke-opacity="0.08" stroke-width="2"/>')
    mh = side * (0.60 if small else 0.50)
    mw, _ = mark_size(mh)
    g = mark_group((size - mw) / 2 - side * 0.01, (size - mh) / 2 + side * 0.01, mh,
                   t['ink'], t['seed'], uid='i')
    return svg_doc(size, size, tile + g, title='Finch')


def boot_svg(w, h):
    """Boot splash: the mark in Paper on Ink, a quiet progress track below.

    The mark is a fixed fraction of the shorter side so it reads the same on a
    laptop panel and a large external display."""
    s = min(w, h)
    mh = s * 0.18
    mw, _ = mark_size(mh)
    cx, cy = w / 2, h / 2
    body = mark_group(cx - mw / 2, cy - mh / 2 - s * 0.03, mh, PAPER, SEED, uid='b')
    tw, th = s * 0.16, max(2, s * 0.004)
    ty = cy + mh / 2 + s * 0.06
    body += (f'<rect x="{cx - tw / 2:.1f}" y="{ty:.1f}" width="{tw:.1f}" height="{th:.1f}" '
             f'rx="{th / 2:.1f}" fill="{LINE}"/>')
    body += (f'<rect x="{cx - tw / 2:.1f}" y="{ty:.1f}" width="{tw * 0.35:.1f}" height="{th:.1f}" '
             f'rx="{th / 2:.1f}" fill="{PAPER}"/>')
    return svg_doc(w, h, body, bg=INK, title='Finch')


def boot_logo_svg():
    """Just the boot mark, transparent, for a kernel or bootloader to centre."""
    return symbol_svg(dark=True, size=256, pad=0)


def social_svg():
    W, H = 1280, 640
    mh = 210
    mw, _ = mark_size(mh)
    wh = 150
    ww = wordmark_width(wh)
    gap = 56
    total = mw + gap + ww
    x = (W - total) / 2
    y = (H - mh) / 2 - 30
    body = mark_group(x, y, mh, PAPER, SEED, uid='s')
    body += wordmark_group(x + mw + gap, y + (mh - wh) / 2 - 10, wh, PAPER, SEED)
    tg, _ = caps_text(TAGLINE, W / 2, y + mh + 70, 18, MIST, weight=10, anchor='middle')
    body += tg
    return svg_doc(W, H, body, bg=INK, title='Finch')


def brand_sheet_svg():
    W, H = 1600, 1000
    g = 24
    cells = []

    def card(x, y, w, h, dark, label, inner):
        t = theme(dark)
        lab, _ = caps_text(label, x + 24, y + 22, 9, t['sub'], weight=12, track=0.5)
        cells.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="18" fill="{t["bg"]}"/>'
                     f'{lab}{inner}')

    # Row 1: primary lockup light and dark.
    rw, rh = (W - 3 * g) / 2, 300
    for i, dark in enumerate((False, True)):
        x, y = g + i * (rw + g), g
        t = theme(dark)
        mh = 120
        mw, _ = mark_size(mh)
        wh = 112
        ww = wordmark_width(wh)
        tot = mw + 30 + ww
        lx = x + (rw - tot) / 2
        ly = y + (rh - mh) / 2 + 4
        inner = mark_group(lx, ly, mh, t['ink'], t['seed'], uid=f'p{i}')
        inner += wordmark_group(lx + mw + 30, ly + (mh - wh) / 2 - 8, wh, t['ink'], t['seed'])
        tg, _ = caps_text(TAGLINE, x + rw / 2, ly + mh + 34, 11, t['sub'], weight=11, anchor='middle')
        card(x, y, rw, rh, dark, 'PRIMARY' if not dark else 'PRIMARY ON INK', inner + tg)

    # Row 2: symbol, mono, icons.
    y2 = g + rh + g
    h2 = 300
    sw = (W - 5 * g) / 4
    specs = [(False, False, 'SYMBOL'), (True, False, 'SYMBOL ON INK'),
             (False, True, 'SINGLE COLOUR')]
    for i, (dark, mono, label) in enumerate(specs):
        x = g + i * (sw + g)
        t = theme(dark)
        mh = 150
        mw, _ = mark_size(mh)
        inner = mark_group(x + (sw - mw) / 2, y2 + (h2 - mh) / 2 + 8, mh, t['ink'],
                           t['ink'] if mono else t['seed'], uid=f's{i}')
        card(x, y2, sw, h2, dark, label, inner)
    x = g + 3 * (sw + g)
    inner = ''
    for j, (dark, sz) in enumerate(((False, 112), (True, 112))):
        t = theme(dark)
        ix = x + 24 + j * (sz + 20)
        iy = y2 + 70
        inner += (f'<rect x="{ix}" y="{iy}" width="{sz}" height="{sz}" rx="{sz * 0.225:.1f}" '
                  f'fill="{t["bg"]}" stroke="{INK}" stroke-opacity="0.12"/>')
        mh = sz * 0.5
        mw, _ = mark_size(mh)
        inner += mark_group(ix + (sz - mw) / 2, iy + (sz - mh) / 2, mh, t['ink'], t['seed'], uid=f'ic{j}')
    sx = x + 24
    for k, sz in enumerate((64, 32, 16)):
        mh = sz * 0.5
        mw, _ = mark_size(mh)
        inner += (f'<rect x="{sx}" y="{y2 + 210}" width="{sz}" height="{sz}" rx="{sz * 0.225:.1f}" '
                  f'fill="{PAPER}" stroke="{INK}" stroke-opacity="0.12"/>')
        inner += mark_group(sx + (sz - mw) / 2, y2 + 210 + (sz - mh) / 2, mh, INK, SEED, uid=f'is{k}')
        sx += sz + 18
    card(x, y2, sw, h2, False, 'APP ICON', inner)

    # Row 3: palette, wordmark, boot.
    y3 = y2 + h2 + g
    h3 = H - y3 - g
    pw = (W - 4 * g) * 0.42
    swatches = [(INK, 'INK', INK), (PAPER, 'PAPER', PAPER), (SEED, 'SEED', SEED),
                (STONE, 'STONE', STONE), (MIST, 'MIST', MIST)]
    inner = ''
    cw = (pw - 48 - 4 * 14) / 5
    for i, (col, name, hx) in enumerate(swatches):
        sx = g + 24 + i * (cw + 14)
        inner += (f'<rect x="{sx:.1f}" y="{y3 + 64}" width="{cw:.1f}" height="{cw:.1f}" rx="12" '
                  f'fill="{col}" stroke="{INK}" stroke-opacity="0.12"/>')
        nt, _ = caps_text(name, sx, y3 + 64 + cw + 18, 10, INK, weight=12, track=0.4)
        inner += nt
        inner += (f'<text x="{sx:.1f}" y="{y3 + 64 + cw + 50:.1f}" font-family="ui-monospace, Menlo, monospace" '
                  f'font-size="13" fill="{STONE}">{hx}</text>')
    card(g, y3, pw, h3, False, 'COLOUR', inner)

    x = g + pw + g
    ww2 = (W - 4 * g) * 0.30
    wh = 84
    wwid = wordmark_width(wh)
    inner = wordmark_group(x + (ww2 - wwid) / 2, y3 + (h3 - wh) / 2 + 6, wh, INK, SEED)
    card(x, y3, ww2, h3, False, 'WORDMARK', inner)

    x += ww2 + g
    bw = W - x - g
    bh = h3
    s = min(bw, bh)
    mh = s * 0.30
    mw, _ = mark_size(mh)
    inner = mark_group(x + (bw - mw) / 2, y3 + (bh - mh) / 2 - 8, mh, PAPER, SEED, uid='bt')
    tw = bw * 0.22
    inner += (f'<rect x="{x + (bw - tw) / 2:.1f}" y="{y3 + (bh + mh) / 2 + 22:.1f}" width="{tw:.1f}" '
              f'height="4" rx="2" fill="{LINE}"/><rect x="{x + (bw - tw) / 2:.1f}" '
              f'y="{y3 + (bh + mh) / 2 + 22:.1f}" width="{tw * 0.35:.1f}" height="4" rx="2" fill="{PAPER}"/>')
    card(x, y3, bw, bh, True, 'BOOT', inner)

    return svg_doc(W, H, ''.join(cells), bg='#E9E6DF', title='Finch brand sheet')


# ---------------------------------------------------------------------------
# Rendering.

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as fh:
        fh.write(text)


def raster(svg_path, png_path, w=None, h=None):
    cmd = ['rsvg-convert', svg_path, '-o', png_path]
    if w:
        cmd += ['-w', str(w)]
    if h:
        cmd += ['-h', str(h)]
    subprocess.run(cmd, check=True)


def png_pixels(path):
    """Minimal PNG reader (8-bit RGBA, as rsvg-convert writes) for the console art."""
    with open(path, 'rb') as fh:
        data = fh.read()
    pos, idat = 8, b''
    w = h = 0
    while pos < len(data):
        ln, = struct.unpack('>I', data[pos:pos + 4])
        typ = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + ln]
        if typ == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', chunk[:10])
            assert depth == 8 and ctype == 6, 'expected 8-bit RGBA'
        elif typ == b'IDAT':
            idat += chunk
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride, rows, prev = w * 4, [], bytearray(w * 4)
    for y in range(h):
        ft = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - 4] if i >= 4 else 0
            b = prev[i]
            c = prev[i - 4] if i >= 4 else 0
            if ft == 1:
                line[i] = (line[i] + a) & 255
            elif ft == 2:
                line[i] = (line[i] + b) & 255
            elif ft == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif ft == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append([tuple(line[x * 4:x * 4 + 4]) for x in range(w)])
        prev = line
    return rows


def console_art(svg_path, tmp, cols=22):
    """finch-init's boot art: the mark as 24-bit half-block characters."""
    png = os.path.join(tmp, 'console.png')
    raster(svg_path, png, w=cols)
    px = png_pixels(png)
    if len(px) % 2:
        px.append([(0, 0, 0, 0)] * cols)

    def colour(p):
        r, g, b, a = p
        return None if a < 110 else (r, g, b)

    lines = []
    for y in range(0, len(px), 2):
        out, last = '', None
        for x in range(cols):
            top, bot = colour(px[y][x]), colour(px[y + 1][x])
            if top is None and bot is None:
                seq = '\\033[0m ' if last != 'none' else ' '
                last = 'none'
            elif bot is None:
                seq = f'\\033[0;38;2;{top[0]};{top[1]};{top[2]}m\\u2580'
                last = None
            elif top is None:
                seq = f'\\033[0;38;2;{bot[0]};{bot[1]};{bot[2]}m\\u2584'
                last = None
            else:
                seq = (f'\\033[0;38;2;{top[0]};{top[1]};{top[2]};'
                       f'48;2;{bot[0]};{bot[1]};{bot[2]}m\\u2580')
                last = None
            out += seq
        lines.append(out + '\\033[0m')
    # Trim blank rows.
    while lines and lines[0].replace('\\033[0m', '').strip() == '':
        lines.pop(0)
    while lines and lines[-1].replace('\\033[0m', '').strip() == '':
        lines.pop()
    return lines


def c_string_utf8(s):
    # ▀ / ▄ as UTF-8 escapes so the header stays ASCII.
    return (s.replace('\\u2580', '\\xe2\\x96\\x80""').replace('\\u2584', '\\xe2\\x96\\x84""'))


def main():
    tmp = tempfile.mkdtemp(prefix='mkbrand.')
    svg = os.path.join(OUT, 'svg')
    icons = os.path.join(OUT, 'icons')
    boot = os.path.join(OUT, 'boot')
    for d in (svg, icons, boot):
        os.makedirs(d, exist_ok=True)

    masters = {
        'symbol.svg': symbol_svg(),
        'symbol-dark.svg': symbol_svg(dark=True),
        'symbol-mono.svg': symbol_svg(mono=True),
        'symbol-mono-dark.svg': symbol_svg(dark=True, mono=True),
        'wordmark.svg': wordmark_svg(),
        'wordmark-dark.svg': wordmark_svg(dark=True),
        'logo.svg': logo_svg(),
        'logo-dark.svg': logo_svg(dark=True),
        'logo-mono.svg': logo_svg(mono=True),
        'logo-stacked.svg': stacked_svg(),
        'logo-stacked-dark.svg': stacked_svg(dark=True),
        'icon.svg': icon_svg(),
        'icon-dark.svg': icon_svg(dark=True),
        'boot-logo.svg': boot_logo_svg(),
        'social-preview.svg': social_svg(),
        'brand-sheet.svg': brand_sheet_svg(),
    }
    for name, text in masters.items():
        write(os.path.join(svg, name), text)

    S = lambda n: os.path.join(svg, n)
    raster(S('logo.svg'), os.path.join(OUT, 'logo.png'), w=1600)
    # UI assets for Finch's own interface (the Rail's mark, the Instrument Bar's wordmark), 1x and 2x
    ui = os.path.join(OUT, 'ui')
    os.makedirs(ui, exist_ok=True)
    for tag in ('', '-dark'):
        for k in (1, 2):
            at = '@2x' if k == 2 else ''
            raster(S(f'symbol{tag}.svg'), os.path.join(ui, f'symbol{tag}{at}.png'), w=28 * k)
            raster(S(f'wordmark{tag}.svg'), os.path.join(ui, f'wordmark{tag}{at}.png'), h=15 * k)
    raster(S('logo-dark.svg'), os.path.join(OUT, 'logo-dark.png'), w=1600)
    raster(S('symbol.svg'), os.path.join(OUT, 'symbol.png'), w=1024)
    raster(S('symbol-dark.svg'), os.path.join(OUT, 'symbol-dark.png'), w=1024)
    raster(S('social-preview.svg'), os.path.join(OUT, 'social-preview.png'), w=1280)
    raster(S('brand-sheet.svg'), os.path.join(OUT, 'brand-sheet.png'), w=1600)

    # Icons. Below 64 px the tile margins eat the mark, so small sizes use a
    # tighter tile drawn at that size.
    for n in (16, 32, 64, 128, 256, 512, 1024):
        for dark, tag in ((False, ''), (True, '-dark')):
            src = os.path.join(tmp, f'icon{tag}-{n}.svg')
            write(src, icon_svg(dark=dark, size=1024, small=n <= 32))
            raster(src, os.path.join(icons, f'icon{tag}-{n}.png'), w=n)
    fav = []
    for n in (16, 32, 48, 64):
        p = os.path.join(tmp, f'fav-{n}.png')
        raster(S('symbol.svg'), p, w=n)
        fav.append(p)
    if shutil.which('magick'):
        subprocess.run(['magick', *fav, os.path.join(icons, 'favicon.ico')], check=True)
    if shutil.which('iconutil'):
        iset = os.path.join(tmp, 'Finch.iconset')
        os.makedirs(iset)
        for n in (16, 32, 128, 256, 512):
            raster(S('icon.svg'), os.path.join(iset, f'icon_{n}x{n}.png'), w=n)
            raster(S('icon.svg'), os.path.join(iset, f'icon_{n}x{n}@2x.png'), w=2 * n)
        subprocess.run(['iconutil', '-c', 'icns', iset, '-o', os.path.join(icons, 'Finch.icns')],
                       check=True)

    # Boot: full-screen splashes for common Apple Silicon panels, and the bare
    # mark at 1x/2x/3x for code that draws its own background.
    for w, h in ((1440, 900), (2560, 1600), (2560, 1664), (3024, 1964), (3456, 2234),
                 (3840, 2160), (5120, 2880)):
        src = os.path.join(boot, f'boot-{w}x{h}.svg') if (w, h) == (2560, 1664) else \
            os.path.join(tmp, f'boot-{w}x{h}.svg')
        write(src, boot_svg(w, h))
        raster(src, os.path.join(boot, f'boot-{w}x{h}.png'), w=w)
    os.replace(os.path.join(boot, 'boot-2560x1664.svg'), os.path.join(svg, 'boot.svg'))
    for k, px in ((1, 128), (2, 256), (3, 384)):
        raster(S('boot-logo.svg'), os.path.join(boot, f'boot-logo@{k}x.png' if k > 1
                                                 else 'boot-logo.png'), w=px)

    # finch-init console art.
    art = console_art(S('symbol-dark.svg'), tmp)
    with open(BANNER_H, 'w') as fh:
        fh.write('/* SPDX-License-Identifier: MIT OR Apache-2.0 */\n'
                 '/* Generated by tools/mkbrand.py: do not edit. The Finch mark in 24-bit\n'
                 ' * colour half-block characters, printed by finch-init at boot. */\n'
                 '#ifndef FINCH_BANNER_ART_H\n#define FINCH_BANNER_ART_H\n\n'
                 'static const char *const finch_banner_art[] = {\n')
        for line in art:
            fh.write(f'\t"{c_string_utf8(line)}",\n')
        fh.write('};\n\n#endif\n')
    shutil.rmtree(tmp)
    print(f'ok: {OUT}')


if __name__ == '__main__':
    main()
