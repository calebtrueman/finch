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
- 2026-10-08: CGImage, CGBitmapContext and CGContext. Bitmap contexts accept
  exactly Apple's layouts (rows aligned to 32 bytes by default). Skia draws
  RGBA/BGRA, gray, alpha-only, 16-bit and float (little-endian) layouts in
  place; for the others (ARGB, 5-bit, big-endian 16-bit and float, gray with
  alpha, CMYK) it draws into a work buffer converted from and back to the
  client's bytes around each operation, over the operation's bounds. Images
  in the common 8-bit layouts are wrapped without copying; the others
  (1 to 32 bits, decode arrays, indexed, Lab, masks, masking colours) are
  unpacked once and cached. Details that had to match: the clip box is kept
  in the default user space; `CGContextStrokeRect` starts at (maxX, minY)
  and runs the other way from `CGPathAddRect` (dashes show it); without
  antialiasing Apple fills every pixel the shape touches, which Finch gets
  by rendering coverage at 4x. `finch-cg-draw-test` compares 36 scenes with
  renders from Apple's CG: exact where the reference is flat, within a
  tolerance on antialiased edges.
- Known gap: CMYK. Apple converts CMYK through its Generic CMYK profile,
  which can't be shipped; Finch converts naively until an open CMYK profile
  is chosen. The draw test leaves CMYK out.
- 2026-10-08: gradients, shadings, functions, patterns and CGLayer. CG
  extends a gradient past each end independently, which Skia's tile modes
  can't, so the gradient's domain is stretched past each end that extends
  (a radial one only until its radius reaches 0) and left transparent past
  the others. Gradients interpolate in their own colour space (sampled and
  converted when the context draws in another). Pattern cells are recorded
  as Skia pictures and drawn cell by cell, clipped to the shape, as Apple's
  are: antialiased cell edges show where cells meet. Known gap: with
  rotated pattern matrices, Apple's cells are spaced slightly differently
  (some device-pixel snapping not yet worked out).
- 2026-10-08: `ImageIO.framework` (`userland/ImageIO`), linked as Apple's
  (Versions/A, 1.0), exporting the CGImageSource/Destination/Metadata
  functions and the 750 string constants the SDK declares, with Apple's
  values. Sources read PNG (libpng), JPEG (libjpeg-turbo), GIF (wuffs),
  WebP (libwebp), BMP and ICO, and return CGImages in Apple's layouts: RGBX
  for opaque 8-bit RGB, little-endian 16-bit, palette PNGs and BMPs as
  indexed, gray as Generic Gray Gamma 2.2, every frame of a GIF composited.
  Properties follow Apple's keys and number types, including the PNG,
  JFIF, GIF, WebP, TIFF, Exif and IPTC dictionaries, EXIF and XMP metadata,
  and Apple's colour naming (ProfileName). Incremental sources report
  Apple's statuses as data arrives. Thumbnails use Apple's sizes and
  layouts (premultiplied ARGB or XRGB, rows padded to 16 bytes, EXIF
  orientation applied on request); the scaling filter is Finch's (Lanczos),
  within a few levels of Apple's. Destinations write PNG and JPEG with
  Apple's chunks and markers (sRGB or an ICC profile, eXIf/Exif, pHYs, JFIF)
  and a quality scale fitted to Apple's quantization. `finch-imageio-test`
  compares 34 generated images and the writers with Apple's ImageIO:
  identical on the host and in the VM; decoded JPEG pixels are
  within 4 levels of Apple's (a different IDCT and upsampler), and on about
  700 PNGs and JPEGs from macOS itself the PNG pixels are identical.
- Known gaps (ImageIO): Apple's CgBI ("crushed" iOS) PNGs are not read. No
  TIFF, HEIF or GIF writing yet; metadata (XMP) objects are empty.
- 2026-10-08: ICC naming as Apple's: a profile becomes a named space only
  when its bytes are exactly a profile Apple's CG hands out (recognised by
  SHA-256 fingerprint; the profiles themselves aren't shipped) or one Finch
  generates. `CGDataConsumerPutBytes` is exported, as Apple's is.
- 2026-10-08: CGFont and text. Metrics come from the font's tables (hhea
  ascent and descent, OS/2 cap and x height, post names, fvar axes keyed by
  name) and match Apple's for the test fonts; glyph boxes and variations
  come from FreeType. Glyphs are drawn as unhinted outlines placed by the
  text matrix, through the path machinery, so every text drawing mode,
  clip, pattern and shadow works. Font smoothing, on by default, darkens
  glyphs: raising coverage to the power 0.72 matches Apple's closely.
  `CGFontCreateWithFontName` looks fonts up by PostScript name in the font
  directories. Skia is built with HarfBuzz now, for CoreText's shaping and
  PDF font subsetting.
- 2026-10-08: CoreText (`userland/CoreText`), linked as Apple's (Versions/A,
  877.4), with every public function and constant (Apple's 130 constant
  values). CTFont reads metrics from the font's tables (OS/2 typographic
  metrics when the font asks for them), CTLine shapes with HarfBuzz after
  splitting by attributes, ICU bidi levels and font coverage, and the
  typesetter cuts lines from text shaped once, as Apple's does, so a line
  broken mid-word keeps its kerning. Details matched: caret offsets sit
  halfway into the kerning and tracking after a glyph and divide
  ligatures evenly; `kCTKernAttributeName` tracks every glyph; line ends
  take the space glyph with no advance, tabs advance to twelve 28-point
  stops, other controls show nothing; cluster breaks count trailing
  whitespace and line breaks don't; frames round each line's ascent,
  descent and leading and keep a line only when its descent fits.
  `finch-ct-test` (fonts, lines, runs, frames, alignment, indents,
  breaking) is identical to Apple's on the host and in the VM. Gaps:
  justification spreads space differently from Apple's (not yet
  compared), start and middle truncation are done as end truncation,
  font features (`CTFontCopyFeatures`) are empty, and the fonts Finch
  ships are still to come.
