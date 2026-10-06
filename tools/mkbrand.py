#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
# Generate branding/ derived assets (dark logo, symbol, icons, favicon, social
# card) from branding/logo.png. Needs Pillow. Usage: tools/mkbrand.py branding
# (then build icons/Finch.icns with iconutil; see branding/BRAND.md).
import sys
from PIL import Image, ImageDraw
B = sys.argv[1]
CHARCOAL=(0x1E,0x23,0x28); GREEN=(0x48,0x6B,0x52); CLOUD=(0xF5,0xF5,0xF2); SLATE=(0x9A,0xA0,0xA6)
logo = Image.open(f'{B}/logo.png').convert('RGBA')

def lum(p): return 0.299*p[0]+0.587*p[1]+0.114*p[2]

# Dark-background variant: dark ink becomes Cloud, the light body becomes a deep
# slate so the bird keeps its shape; green stays.
dark = logo.copy(); px = dark.load()
for y in range(dark.height):
    for x in range(dark.width):
        r,g,b,a = px[x,y]
        if a == 0: continue
        L = lum((r,g,b)); greenish = g > r + 12 and g > b
        if greenish: continue
        if L < 90:   px[x,y] = (*CLOUD, a)
        elif L > 200: px[x,y] = (0x3A,0x41,0x48, a)
dark.save(f'{B}/logo-dark.png')

# Symbol only: the bird, square with margin.
x0,y0,x1,y1 = 261,187,923,760
bird = logo.crop((x0,y0,x1,y1)); side = int(max(bird.size)*1.18)
sym = Image.new('RGBA',(side,side),(0,0,0,0)); sym.paste(bird,((side-bird.width)//2,(side-bird.height)//2),bird)
sym.save(f'{B}/symbol.png')

# App icon: symbol on a Cloud rounded square (macOS-style margins).
def icon(n, bg=CLOUD, art=sym):
    im = Image.new('RGBA',(n,n),(0,0,0,0)); d = ImageDraw.Draw(im)
    m = round(n*0.1); d.rounded_rectangle((m,m,n-m-1,n-m-1), radius=round(n*0.18), fill=(*bg,255))
    inner = round((n-2*m)*0.86); a = art.resize((inner,inner), Image.LANCZOS)
    im.paste(a, ((n-inner)//2, (n-inner)//2 + round(n*0.01)), a); return im
symdark = sym.copy(); p2 = symdark.load()
for y in range(symdark.height):
    for x in range(symdark.width):
        r,g,b,a = p2[x,y]
        if a and not (g > r+12 and g > b):
            L = lum((r,g,b)); p2[x,y] = ((*CLOUD,a) if L < 90 else (0x3A,0x41,0x48,a) if L > 200 else (r,g,b,a))
for n in (16,32,64,128,256,512,1024):
    icon(n).save(f'{B}/icons/icon-{n}.png')
    icon(n, CHARCOAL, symdark).save(f'{B}/icons/icon-dark-{n}.png')
icon(256).save(f'{B}/icons/favicon.ico', sizes=[(16,16),(32,32),(48,48),(64,64)])

# GitHub social preview 1280x640: logo on Charcoal.
card = Image.new('RGBA',(1280,640),(*CHARCOAL,255))
l = dark.resize((560,560), Image.LANCZOS); card.paste(l,((1280-560)//2,40),l)
card.convert('RGB').save(f'{B}/social-preview.png')
print('ok')
