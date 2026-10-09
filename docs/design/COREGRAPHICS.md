# CoreGraphics, CoreText and ImageIO

Every AppKit app draws through CoreGraphics (Quartz 2D). Apple's is closed,
and so are CoreText and ImageIO beside it. Finch builds its own on open
renderers, after Foundation and before the window server and AppKit
(`docs/ROADMAP.md`, Phase 2).

## What Apple's exports

Measured from the macOS 26 SDK (`.tbd` files and headers):

| Framework | Exported symbols | Public functions |
|---|---|---|
| CoreGraphics | 4,613 | 716 |
| CoreText | 929 | about 200 |
| ImageIO | 6,303 | about 60 |

CoreGraphics' public API has two halves:

- **Drawing** (about 500 functions): `CGContext` and bitmap contexts, paths,
  colours and colour spaces, images and data providers, gradients, shadings,
  patterns, layers, fonts, affine transforms and geometry, and PDF (contexts
  to write it, documents and scanners to read it).
- **The window server's client side** (about 210): `CGWindow*` window lists,
  `CGEvent*` event taps and synthesis, `CGDisplay*` display configuration and
  streams, remote operation, and sessions. On macOS these are calls into
  WindowServer (SkyLight). Finch's land with its own window server.

The other exported symbols are private (`CGDisplayList*`, `CGContextDelegate*`,
`CGRenderingState*`, …) and are written as apps or Apple's open-source code
turn out to need them. `tools/check-framework-api.py` measures coverage, as it
does for Foundation.

## The renderer: Skia

Finch's CoreGraphics is Apple's C API in front of **Skia** (BSD-3-Clause), the
2D library Chrome, Android and Flutter draw with. Skia's model is close to
Quartz's: paths with even-odd and winding fills, strokes with caps, joins,
miter limits and dashes, a clip stack, affine and perspective matrices,
Porter-Duff and separable blend modes, linear, radial and conic gradients,
image shaders and filters, and a PDF backend. Most CG drawing calls map to one
Skia call.

The alternatives considered:

- **Cairo** (LGPL-2.1 or MPL-1.1): close to Quartz too, but it has no
  maintained GPU path, and its PDF output and text are weaker than Skia's.
- **Writing a rasterizer**: coverage-exact antialiasing, gradient dithering
  and the blend modes are years of work Skia has already done.
- **Blend2D** (Zlib): fast, but CPU-only, with no PDF backend.

Skia is pinned to the chrome/m155 commit
`29ed1e87a0a50f3d8347e988842d9d59e7573efa`. `userland/skia/build.sh` fetches
it and the libraries it builds against, shallow at the commits its `DEPS`
file pins, and builds static libraries that CoreGraphics links. Only the CPU
raster backend is built for now. A GPU backend comes with Metal on Mesa
(Phase 4).

Skia's macOS build normally calls Apple's CoreGraphics, ImageIO and CoreText
(`SkImageGeneratorCG`, the `src/utils/mac` helpers, the CoreText font
manager). Finch's patch `userland/skia/patches/0001-no-apple-frameworks.patch`
adds `skia_use_apple_frameworks=false`, which leaves them out. The build
fails if `libskia.a` references any `CG*` or `CT*` symbol.

## How the pieces fit

| Apple framework | Finch's, over |
|---|---|
| CoreGraphics: contexts, paths, colours, images, gradients | Skia (`SkCanvas`, `SkPath`, `SkPaint`, shaders) |
| CoreGraphics: colour spaces, ICC profiles | skcms (Skia's, BSD-3), with lcms2 (MIT) if it falls short |
| CoreGraphics: `CGPDFContext` (writing) | Skia's PDF backend (`SkPDF`) |
| CoreGraphics: `CGPDFDocument`, scanner (reading) | A Finch PDF parser (PDFium, BSD-3, is the fallback) |
| CoreGraphics: `CGFont`, glyph drawing | FreeType (FTL) through Skia's FreeType typeface |
| CoreText: font descriptors and collections, shaping, lines, frames | HarfBuzz (MIT) for shaping, FreeType for metrics, ICU (already built) for line breaking and bidi |
| ImageIO: `CGImageSource`, `CGImageDestination` | Skia's codecs: libpng, libjpeg-turbo, libwebp, wuffs (GIF), BMP, ICO; then libtiff, and libheif for HEIC |

### Types

CG and CT types are CF types on macOS: `CFGetTypeID`, `CFRetain` and
`CFCopyDescription` work on them, and they bridge to ObjC as `__NSCFType`
(so `NSArray` can hold `CGColorRef`s). Finch registers them with
CoreFoundation's runtime the same way, so they behave the same.

### Coordinates

Quartz puts the origin at the bottom left, with y going up. Skia puts it at the top left, with y going down. A bitmap context
starts with a flip as its base CTM, so drawing lands on the same pixels as
Apple's. `CGContextGetCTM` reports the user transform without the flip, as
Apple's does. `CGBitmapContextCreate`'s buffer layout (row order, byte order,
premultiplication and `CGBitmapInfo` flags) is matched exactly, because apps
read and write those bytes directly.

## Fonts

Apple's fonts can't be redistributed, so Finch ships open fonts and maps
Apple's names to them:

| Apple font | Finch ships (licence) |
|---|---|
| System font (SF Pro), `.AppleSystemUIFont` | Inter (OFL-1.1) |
| SF Mono, Menlo, Monaco | JetBrains Mono or DejaVu Sans Mono (OFL / Bitstream Vera) |
| Helvetica, Helvetica Neue, Arial | Liberation Sans (OFL-1.1, metric-compatible with Arial) |
| Times, Times New Roman | Liberation Serif (OFL-1.1) |
| Courier, Courier New | Liberation Mono (OFL-1.1) |
| Apple Color Emoji | Noto Color Emoji (OFL-1.1) |
| CJK, other scripts | Noto Sans / Serif families (OFL-1.1) |

Text laid out in substituted fonts won't break lines in exactly the same
places as on macOS. Apps that need exact metrics bundle their own fonts,
and those load through `CTFontManager` as on macOS.

## Testing

The tests follow Foundation's:

- **API with exact answers** (geometry, affine transforms, path construction and
  iteration, bounding boxes, colour-space and image properties, `CGBitmapInfo`
  handling, PDF object trees): one result per line, diffed against
  Apple's CoreGraphics on the host and then run in the VM.
- **Pixels**: test programs draw scenes into bitmap contexts on Apple's CG and
  on Finch's, then compare them per pixel. Antialiasing differs between
  rasterizers, so edges are compared with a tolerance (at most 1 in 255 per
  channel, plus a bounded count of differing edge pixels). Fills, solid
  colours and blend results away from edges must match exactly.
- **ImageIO**: decode the same files with both and compare pixels and
  properties. Encoders round-trip.

## Order

1. CoreGraphics' drawing half: geometry and transforms, paths, colour spaces
   and colours, bitmap contexts, images and data providers, gradients, then
   shadings, patterns, layers and PDF writing.
2. ImageIO over Skia's codecs.
3. CoreText over HarfBuzz and FreeType, with the open fonts.
4. The window-server half of CoreGraphics, with Finch's window server (Tier 2).
5. PDF reading.

## Status

- 2026-10-08: Skia m155 builds for arm64e with FreeType and the open codecs,
  with no references to Apple's graphics frameworks (`userland/skia/build.sh`).
- 2026-10-08: `CoreGraphics.framework` (`userland/CoreGraphics`), linked as Apple's
  (Versions/A, 1965.4.5, compatibility 64), exporting only `CG*` symbols. CG
  types register with CoreFoundation's runtime. Geometry and affine transforms
  (including Apple's handling of null, infinite and negative rects, and
  `CGAffineTransformDecompose`) and CGPath match Apple's line for line in
  `finch-cg-test`, on the host and in the VM. Paths keep the elements they
  were built from, so `CGPathApply` returns what Apple's does: arcs are
  Bézier quarters plus a remainder, built on a unit circle and mapped through
  translate · scale · rotate, with Apple's quarter-circle constant
  0.5522847498.
- 2026-10-08: colour spaces, colours, data providers and consumers. All of
  Apple's named spaces, with their property-list IDs, descriptions and
  linearized/extended variants, and colour matching through XYZ (D50) that
  agrees with Apple's to four decimals. The colorimetry is the standards'
  (Apple's generic spaces: Generic RGB at gamma 1.8 with its own primaries,
  "Gray Gamma 2.2" on the sRGB curve). Matrices are normalised so white maps
  to D50 exactly, which keeps neutrals neutral, as Apple's CMM does. ICC
  profiles are parsed with skcms, and a profile that matches a named space
  becomes that space. The profiles CG hands out are generated by Finch.
