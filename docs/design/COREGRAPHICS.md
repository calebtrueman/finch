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
| CoreGraphics: `CGPDFDocument`, scanner, `CGContextDrawPDFPage` (reading) | A Finch PDF parser and interpreter (ISO 32000), zlib, Skia's codecs, FreeType |
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
Apple's names to them. `userland/fonts/build.sh` downloads pinned upstream
releases (each checked by SHA-256), installs the font files unmodified into
`/System/Library/Fonts` and their licences into
`/usr/share/finch/licenses/<family>/`. 51 files, 59 MB:

| Font (version, licence) | Faces | Size | Stands in for |
|---|---|---|---|
| Inter 4.1 (OFL-1.1) | all 18 static faces, Thin to Black, upright and italic | 7.2 MB | the system font (SF Pro), Lucida Grande |
| Liberation Sans, Serif, Mono 2.1.5 (OFL-1.1) | regular, bold, italic, bold italic | 4.2 MB | Helvetica, Helvetica Neue, Arial; Times, Times New Roman; Courier, Courier New (metric-compatible with Arial, Times New Roman and Courier New) |
| DejaVu Sans Mono 2.37 (Bitstream Vera) | book, bold, oblique, bold oblique | 1.1 MB | Menlo, Monaco, SF Mono. Menlo is derived from DejaVu Sans Mono, so the metrics match Menlo's; JetBrains Mono doesn't. |
| Noto Sans, Noto Serif 2.015 (OFL-1.1) | regular, bold, italic, bold italic | 3.6 MB | fallback for Latin, Greek, Cyrillic |
| Noto Sans Symbols 2.003, Symbols 2 2.008 (OFL-1.1) | regular | 0.8 MB | Apple Symbols, symbol fallback |
| Noto Sans Arabic 2.013, Noto Sans Hebrew 3.001 (OFL-1.1) | regular, bold | 0.3 MB | Geeza Pro, Arial Hebrew, right-to-left fallback |
| Noto Sans CJK SC 2.004 (OFL-1.1) | regular, bold | 32 MB | PingFang, Hiragino, Apple SD Gothic Neo. Every Noto Sans CJK face covers Chinese, Japanese and Korean; the SC face because PingFang SC is Apple's default Han fallback. Japanese and Korean text gets Simplified Chinese glyph forms where they differ. |
| Noto Color Emoji 2.051 (OFL-1.1) | CBDT colour bitmaps | 10.2 MB | Apple Color Emoji |

The Noto fonts are the unhinted builds, as Finch draws glyphs unhinted.
The fonts are installed into `build/root`, so the VM ramdisk carries them (it
is 1 GiB, and about 470 MB was in use before the fonts).

**Names.** `userland/fonts/FinchFonts.h` holds the alias table, shared by
CoreText's registry (`CTFontCreateWithName`, descriptors) and CoreGraphics'
(`CGFontCreateWithFontName`). A name resolves to an alias only when no
registered or installed font has it, so a real font of that name (bundled by
an app, or Apple's on a macOS host) always wins. Alias names compare
ignoring case, as Apple's names do.

| Apple names (PostScript, full and family) | Finch font |
|---|---|
| Helvetica, Helvetica-Light, Helvetica Neue, HelveticaNeue(-UltraLight, -Thin, -Light, -Medium), Arial, ArialMT | LiberationSans |
| Helvetica-Bold, HelveticaNeue-Bold, HelveticaNeue-CondensedBold, Arial-BoldMT, "Arial Bold" | LiberationSans-Bold |
| Helvetica-Oblique, HelveticaNeue-Italic, Arial-ItalicMT | LiberationSans-Italic |
| Helvetica-BoldOblique, HelveticaNeue-BoldItalic, Arial-BoldItalicMT | LiberationSans-BoldItalic |
| Times, Times-Roman, Times New Roman, TimesNewRomanPSMT (and -Bold, -Italic, -BoldItalic forms) | LiberationSerif (and its faces) |
| Courier, Courier New, CourierNewPSMT (and -Bold, -Oblique/-Italic forms) | LiberationMono (and its faces) |
| Menlo, Menlo-Regular, Monaco, SF Mono, SFMono-Regular, .AppleSystemUIFontMonospaced | DejaVuSansMono |
| Menlo-Bold, SFMono-Bold, SFMono-Semibold; Menlo-Italic; Menlo-BoldItalic | DejaVuSansMono-Bold; -Oblique; -BoldOblique |
| .AppleSystemUIFont, System Font, .SF NS, .SFNS-Regular, SF Pro, SF Pro Text, SF Pro Display, SFProText-Regular, LucidaGrande, .Keyboard | Inter-Regular |
| .AppleSystemUIFontBold, .SFNS-Bold, SFProText-Bold, LucidaGrande-Bold | Inter-Bold |
| SF weights: Ultralight, Thin, Light, Medium, Semibold, Heavy, Black (.SFNS-, SFProText-, SFProDisplay-) | Inter-ExtraLight, -Thin, -Light, -Medium, -SemiBold, -ExtraBold, -Black |
| Apple Color Emoji, AppleColorEmoji | NotoColorEmoji |
| Apple Symbols | NotoSansSymbols-Regular |
| PingFang SC/TC/HK and their faces, Hiragino Sans (W3), Hiragino Kaku Gothic ProN, Hiragino Mincho ProN, Apple SD Gothic Neo, Heiti SC | NotoSansCJKsc-Regular (Semibold, W6 and Bold faces: NotoSansCJKsc-Bold) |
| Geeza Pro, SF Arabic; GeezaPro-Bold | NotoSansArabic-Regular; -Bold |
| Arial Hebrew, SF Hebrew; ArialHebrew-Bold | NotoSansHebrew-Regular; -Bold |

The full list is in `FinchFonts.h`. As on macOS, a name that matches nothing
gets Helvetica (Liberation Sans), and so does text with no font attribute
(`CTDefaultFont`, Helvetica 12). `CTFontCreateUIFontForLanguage` returns
Apple's UI fonts at Apple's sizes (system 13, small 11, mini 9, views and
control content 12, label 10, user font Helvetica 12, user fixed pitch Menlo
10), emphasized ones bold: Inter-Regular or Inter-Bold. macOS refuses the
system font's private names (`.SFNS-Regular` by name gets Times New Roman);
Finch resolves them to Inter. `CTFontCreateCopyWithSymbolicTraits` finds a
family's bold and italic faces among the installed fonts.

**Fallback.** Where a font has no glyph, CoreText cascades through Inter,
Noto Sans, Noto Sans Arabic, Noto Sans Hebrew, Noto Sans CJK SC, Noto Sans
Symbols and Symbols 2, DejaVu Sans Mono, Noto Color Emoji and Liberation
Sans, taking the bold face of each when the text is bold. Characters in the
emoji planes, and any character followed by U+FE0F, go to the emoji font
first; variation selectors, zero-width joiners, skin-tone modifiers and tag
characters stay in the run of the character before them, so HarfBuzz shapes
emoji sequences as one glyph. `CTFontCopyDefaultCascadeListForLanguages`
returns the same list.

**Font directories.** Both registries index `/System/Library/Fonts`,
`/Library/Fonts` and `~/Library/Fonts`, as on macOS. `FINCH_FONT_DIRS`, a
colon-separated list, replaces them, so Finch's frameworks can be run on
the macOS host against `build/root/System/Library/Fonts` instead of Apple's
fonts (it's ignored in set-id processes):

    DYLD_FRAMEWORK_PATH=build/root/System/Library/Frameworks \
    FINCH_FONT_DIRS=build/root/System/Library/Fonts \
        build/userland/finch-ctfonts-test | diff userland/tests/ctfonts-expected.txt -

`finch-ctfonts-test` prints what each Apple name resolves to (CoreText and
CoreGraphics), its metrics, the UI fonts, the default font, bold and italic
copies, and the fallback fonts and runs for Latin, Greek, Cyrillic, Chinese,
Japanese, Korean, Arabic, Hebrew, symbols and emoji (including ZWJ and
skin-tone sequences). Apple's run necessarily names Apple's fonts, so the
output is compared with `ctfonts-expected.txt` rather than with Apple's.

Text laid out in substituted fonts won't break lines in exactly the same
places as on macOS (only Liberation is metric-compatible, and with Arial,
Times New Roman and Courier New rather than Helvetica, Times and Courier).
Apps that need exact metrics bundle their own fonts, and those load through
`CTFontManager` as on macOS.

**Colour glyphs.** As on macOS, CoreText draws emoji and CoreGraphics'
glyph calls don't: Apple's `CGContextShowGlyphs*` draw every glyph as its
outline (nothing, for a bitmap emoji), while its CoreText draws colour
glyphs as images. Finch's CoreText calls `CGContextFinchShowGlyphsWithColor`
(Finch-only), which has Skia draw the glyphs that have colour forms (CBDT
and sbix bitmaps, COLR version 0 layers) from the font, through the CTM and
text matrix, with the context's alpha, blend mode, shadow and clip, and the
fill colour ignored; a clear fill draws nothing; every text drawing mode
draws them, and the clipping modes clip to their outlines (none, for a
bitmap), all as measured on Apple's. COLR version 1 glyphs are drawn as
outlines, as Apple's CoreText does. Noto Color Emoji is larger than Apple
Color Emoji (its advance is 1.245 em, Apple's 1 em) and sits a little
lower, so a line with emoji is wider than on macOS.

Gaps: fonts report no stylistic class (Apple sets `kCTFontSansSerifClass`
and the like from the OS/2 table); only the first face of a `.ttc`
collection is indexed; an sbix glyph is placed by its bitmap's own origin,
not offset by its outline's bounds as Apple's are (Apple Color Emoji draws
0.125 em higher than on macOS); a text clip drawn through `CTLineDraw` is
lost (Apple's keeps it, as `CTFontDrawGlyphs` now does).

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
5. PDF reading (done, with PDF writing: see Status).

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
- 2026-10-08: The open fonts (`userland/fonts`, 59 MB) and Apple's font
  names aliased onto them in both CoreText and CoreGraphics (see "Fonts"):
  the default font, the UI fonts, bold and italic faces of a family, and a
  fallback cascade for other scripts and emoji. `FINCH_FONT_DIRS` points
  both registries at `build/root`'s fonts on the host. `finch-ctfonts-test`
  (Finch-only) matches `ctfonts-expected.txt`; `finch-ct-test` is still
  identical to Apple's, with and without Finch's fonts.
- 2026-10-08: PDF. `CGPDFContext` is a CGContext over a page canvas from
  Skia's PDF backend, so all drawing works on it; glyphs filled in a plain
  colour become PDF text in a subset of the font (HarfBuzz), the rest are
  outlines. Skia only writes media boxes at the origin, so a final pass
  reads its file back with Finch's parser and writes the document out as
  Quartz's API describes it: page boxes (a media box away from the origin
  through a translation prefixed to the content), links and destinations,
  the information dictionary (text strings in UTF-16 when not ASCII,
  keyword arrays joined as Apple's), outlines, XMP metadata, output intents,
  and encryption with revision 4, AES-128, P bits as Apple's sets them.
  Reading is Finch's own: cross-reference tables and streams, object
  streams, incremental updates, a rebuilt table for broken files, Flate
  (with predictors), LZW, ASCII, run-length and DCT data, the standard
  security handler (revisions 2 to 6: RC4 and AES through CommonCrypto),
  the page tree with inheritance, outlines, and the scanner. Apple's
  behaviour, observed and matched: rotation as written (not normalized),
  bleed, trim and art boxes default to the crop box and aren't clipped to
  it, the drawing transform never scales up and treats a total rotation
  that isn't a multiple of 90 as none, a locked document still hands out
  its (undecrypted, then cached) objects, a wrong password locks an open
  document, dates run on past December, outline items going to named
  destinations are left out, the scanner only calls back for PDF's own
  operators (operands pile up across unknown ones, and an inline image
  arrives as "EI" with its stream on the stack), and a resource is looked
  up in a content stream's parent only when it has no resources of its
  own. `CGContextDrawPDFPage` interprets content through CGContext calls,
  in the current user space with no clip: every colour space (separation
  and DeviceN through tint transforms, indexed, ICC, calibrated, Lab), all
  four function types, images with soft masks, stencils and colour keys,
  inline images, shadings (axial and radial as CGShading; function-based
  and mesh shadings by subdivision, aliased as Apple's), tiling and shading
  patterns, forms and transparency groups, soft masks (drawn into a gray
  bitmap at device resolution), and text in embedded TrueType, CFF and
  Type 1 fonts, Type 3 fonts, and substitutes for the standard 14.
  `finch-cgpdf-test` is identical to Apple's on the host: documents written
  and read back by each CoreGraphics (information, boxes, links, outlines,
  encryption and permissions), hand-written files printed object by object
  and traced through the scanner, drawing transforms, scenes drawn into a
  PDF and drawn back, and 16 hand-written pages against Apple's renders
  (`cgpdf-reference.bin`). Apple's CG reads PDFs Finch writes, and Finch's
  reads Apple's, with the same results. On the 743 PDFs under /System,
  /Library and /Applications, structure matches Apple's reader everywhere
  and first-page renders match closely. Two CG-wide fixes came with it:
  images draw smoothed at the default quality even when they ask not to be
  (as Apple's do), and a text-smoothing layer covers only its glyphs.
- Known gaps (PDF): tagged PDF (`CGPDFContextBeginTag` and the structure
  trees) is accepted but not written; drawing outside the media box is cut
  off by Skia's page (Apple's keeps it in the content); encryption is
  written as AES-128 whatever key length is asked for, and linearized output
  isn't produced. JPEG 2000, JBIG2 and CCITT images aren't decoded,
  predefined CJK CMaps other than Identity aren't available, and vertical
  text advances horizontally. Apple's renderer converts Lab colours
  differently from its own CGColorSpace, which Finch follows. Drawing
  system PDFs takes about six times as long as Apple's.
- 2026-10-08: Colour glyphs (see "Fonts"). Apple's CoreText draws an emoji
  as an image and then shows its glyph as an outline; Apple's
  `CGContextShowGlyphs*` alone draw nothing for it (measured on macOS 26
  with Apple Color Emoji, and with COLR test fonts). Finch's CoreText draws
  them through `CGContextFinchShowGlyphsWithColor`, Skia drawing CBDT, sbix
  and COLR version 0 glyphs from the font. Measured against Apple's with
  each emoji font at 12, 40 and 100 points: the ink sits where Apple's does
  (within the fonts' own differences), and the fill colour, text drawing
  mode, antialiasing and smoothing settings don't change it, the context
  alpha, CTM, text matrix, shadow and blend mode do. Fixes on the way: a
  bitmap-only font's units per em come from its head table (FreeType
  reports none, and CT and CG had taken 1000, so Noto Color Emoji's
  metrics were 2.048 times too large) and its glyph bounds from the
  strike's bitmaps; a COLR glyph's outline is FreeType's (Skia has none
  for it); `CTFontDrawGlyphs` applies the context's text matrix and leaves
  the font and any text clip in the context, as Apple's does; the
  fill-and-clip text modes kept the clip only when font smoothing was off.
  `finch-ctfonts-test` draws emoji through CoreText and CoreGraphics and
  reports where they ink and in which colours.
