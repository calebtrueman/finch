# Asset catalogs

Mac apps keep their named colours, images and data in a compiled asset
catalog, `Contents/Resources/Assets.car`, made by `actool` from an
`.xcassets` folder. Apple reads them with its private CoreUI framework, which
AppKit links. Finch has its own CoreUI (`userland/CoreUI`, installed as
`/System/Library/PrivateFrameworks/CoreUI.framework`, current version 974.1)
with the part of Apple's API that AppKit and apps use, and AppKit's
`colorNamed:`, `imageNamed:` and `NSDataAsset` sit on it
(`userland/AppKit/NSAssetCatalog.m`).

The format below is Finch's own reading of real catalogs: actool's output for
`userland/tests/assets-test.xcassets` (for macOS 26, 10.13, 10.11 and 10.9), the
catalogs of the apps in `/System/Applications`, and the system catalogs of
AppKit and `SystemAppearance.bundle`, checked against `assetutil --info` and
against what Apple's CoreUI returns. Apple's undocumented deepmap2 codec was
learned by disassembling its decoder in vImage (`vImageDeepmap2Decode` and
its helpers). No Apple code or catalog data is in Finch's tree.

## The container: a BOM store

A `.car` file is a BOM ("bill of materials") store, the container format of
installer receipts. Its header and index are big-endian:

| Offset | Field |
|---|---|
| 0 | `"BOMStore"` |
| 8 | version (1), number of blocks |
| 16 | index offset, index length |
| 24 | variables offset, variables length |

The **index** is a count followed by `{u32 offset, u32 length}` per block
(some slots unused). The **variables** are a count followed by
`{u32 block, u8 name length, name}`: named entry points into the blocks.

A **tree** variable points at a block `"tree"`, version, the root page's block,
block size, path count, a flag. A page is `u16 isLeaf, u16 count, u32 next
leaf, u32 previous leaf`, then `count` pairs `{u32 value block, u32 key
block}`. Interior pages' values are child pages; reading descends the leftmost
branch and follows the leaves' `next` chain. Keys are sorted. One tree
(BITMAPKEYS) stores its keys inline as the u32 itself.

## The catalog's variables

Everything inside the blocks is little-endian.

- **CARHEADER** (436 bytes): `"RATC"` (CTAR), CoreUI version (974), storage
  version (17), timestamp, rendition count, a 128-byte main version string
  (`@(#)PROGRAM:CoreUI  PROJECT:CoreUI-974.1`), a 256-byte version string
  (`Xcode 26.4.1 ... via AssetCatalogAgent`), a UUID, a checksum, the schema
  version (2), the colour space id and the key semantics.
- **KEYFORMAT**: `"tmfk"`, version, count, then one u32 attribute id per
  position of a rendition key. The ids (Apple's `kCRTheme...Name`): 1 element,
  2 part, 3 size, 4 direction, 6 value, 7 appearance, 8 dimension 1,
  9 dimension 2, 10 state, 11 layer, 12 scale, 13 localization, 14 presentation
  state, 15 idiom, 16 subtype, 17 identifier, 18 previous value, 19 previous
  state, 20/21 size classes, 22 memory class, 23 graphics class, 24 display
  gamut (0 sRGB, 1 P3), 25 deployment target, 26 glyph weight, 27 glyph size.
  A catalog lists only the attributes it uses.
- **RENDITIONS** (tree): key = one u16 per KEYFORMAT attribute; value = a CSI
  rendition (below).
- **FACETKEYS** (tree): key = an asset's name (`"AccentRed"`, `"Folder/Nested"`
  for a namespace folder); value = its key token: u16 hot spot x and y, u16
  count, then `{u16 attribute, u16 value}` pairs fixing the name's element,
  part and identifier (and sometimes a deployment target). Every rendition of a
  name shares its identifier.
- **APPEARANCEKEYS** (tree): appearance name to u16 id: `NSAppearanceNameSystem`
  0 (the "Any" appearance), `NSAppearanceNameDarkAqua` 1,
  `NSAppearanceNameAccessibilitySystem` 3, `ISAppearanceTintable` ... A catalog
  lists only the appearances it has variants for.
- BITMAPKEYS (per identifier, a bitmap of the key values in use),
  EXTENDED_METADATA (`"META"`: deployment platform and version), and
  others: not needed to look things up.

Parts seen: 181 image (and data), 217 colour, 42 an image's preserved PDF or
SVG, 218 multisize image set, 220 app icon sizes (dimension 2 = the size
index), 245 icon stack, 247 gradient. Element 85 is a named asset, 9 a packed
atlas.

## CSI renditions

Each rendition value is a CSI ("CoreStructuredImage") header, 184 bytes:

| Offset | Field |
|---|---|
| 0 | `"ISTC"` (CTSI), version 1 |
| 8 | rendition flags: bit 2 vector-based; bits 3-4 template rendering mode (1 template, 2 automatic, 0 none) |
| 12 | width, height in pixels; scale x 100 |
| 24 | pixel format: `'ARGB'` (BGRA, premultiplied), `'GA8 '`, `'RGBW'` (RGBA half floats), `'GA16'` (gray-alpha half floats), `'PDF '`, `'SVG '`, `'DATA'`, `'JPEG'`, `'HEIF'`, 0 |
| 28 | colour space id (low byte): 1 sRGB, 2 gray gamma 2.2, 3 Display P3, 4 extended sRGB, 5 extended linear sRGB, 6 extended gray |
| 32 | modification time; u16 layout; u16 0; the source file name (128 bytes) |
| 168 | TLV area length, 1, 0, payload length |

then the TLVs (`{u32 type, u32 length, value}`) and the payload.

Layouts: 10-12 one-part images (12 the usual "scale"), 20-25 three-part and
30-39 nine-part (sliced) images, 6 gradient and 7 effect (theme catalogs), 9 a
PDF or SVG, 1000 raw data, 1003 an image inside an atlas, 1004 an atlas,
1009 colour, 1010 multisize image set, 1017 SF-symbol-style vector glyph,
1019 icon stack, 1020 icon group, 1021 named gradient.

TLVs: 1001 slices (count, then rectangles), 1003 metrics (count, insets, the
pixel size), 1004 blend mode and opacity (u32, float), 1005 a data asset's
UTI (u32 length, 0, the string with its NUL), 1006 EXIF orientation, 1007 the
stored row bytes of a bitmap (rows may be padded: 52 pixels of ARGB are
stored 224 bytes apart), 1010 an atlas link (below).

All the four-character tags are stored as little-endian u32s, so in the file
they read backwards: `ISTC`, `MLEC`, `RLOC`, `DWAR`, `KLNI`, `KCBC`.

### Colours (`"RLOC"`, COLR)

`"RLOC"`, version 1, u8 colour space id, u8 flags, 2 bytes, u32 count, then
`count` doubles (the components and alpha, exactly as given in the colour
set, rounded to floats by actool unless written in hex). With flag bit 0 the
colour refers to a system colour: another `"RLOC"`, 1, a length and the
name (`systemOrangeColor`, `separatorColor`, ...).

### Raw data (`"DWAR"`, RAWD)

`"DWAR"`, u32 flags (bit 0: the bytes are an LZFSE stream), u32 length, the
bytes. Data assets, PDFs, SVGs, and JPEG and HEIF images kept as they were.

### Bitmaps (`"MLEC"`, CELM)

`"MLEC"`, u32 flags (bit 0: the image is in chunks of rows; bit 1: it's
opaque), u32 compression, u32 length (bytes, or the number of chunks). Chunks
are `"KCBC"`, 0, 0, rows, length, data, top to bottom. Compressions:

| # | Name | Data |
|---|---|---|
| 0 | none | the rows (1007 row bytes apart) |
| 1 | RLE | type (1-2 bytes, 3 halfwords, 4+ words per element), width, height, a u32 offset per row; each row is runs of a u32 (low 24 bits count; high bit set: one element repeated, else that many literal elements) |
| 2 | zip | a gzip stream of the rows |
| 3 | LZVN | a raw LZVN stream of the rows |
| 4 | LZFSE | an LZFSE (`bvx2`) stream of the rows |
| 11 | deepmap2 | a 16-byte header (version 1, vImage format, length, 0), then a deepmap2 stream |
| 12 | DXT | GPU texture blocks (seen only in PencilKit); not read |

actool writes deepmap2 for almost every bitmap since macOS 10.15 targets,
LZFSE for app icons, and RLE, zip and uncompressed data for old targets.

### Atlases

actool packs small images into atlases (`ZZZZPackedAsset-<scale>.<n>.<n>-gamut<g>`,
element 9, layout 1004) with a one-pixel border around each. An image in one
is a layout-1003 rendition without a payload; its TLV 1010 is `"KLNI"`, 0, the
frame (x, y, width, height) with the origin at the atlas's **bottom left**, the
image's own layout (u16), a key length (u32) and the atlas's key as
`{u16 attribute, u16 value}` pairs (the others 0).

## Deepmap2

A deepmap2 stream starts with 12 bytes: `"dmp2"`, encoding, a flag (1),
a depth (10), the pixel format (1 gray, 2 gray-alpha, 3 RGB, 4 RGBA in 8 bits;
17-20 the same in half floats), and u16 tile width and height. Except for
encoding 1, tiles follow left to right and top to bottom, each a u32 length
and its bytes; one tile usually covers the image. Inner payloads under 4 KiB
are raw LZVN, larger ones LZFSE.

- **1, none**: the pixels.
- **3, lossless**: LZVN/LZFSE of the pixels.
- **4, palette** (RGBA only): u16 count (at most 256) and u16 entry size (3 or 4)
  after the header, then 4 bytes per entry (BGRA, premultiplied). A tile is a
  byte per pixel (entry size 4), or an alpha plane then the indexes (entry
  size 3, the entry's alpha replaced).
- **2, default**: a lossless transform. Decompressed, a tile is: the alpha
  plane (formats with alpha), a predictor byte per row, then two byte planes of
  16-bit values, high bytes first, each row holding 3 values per pixel (Y, Co,
  Cg; gray formats store Y only and the rest are 0). A value is
  `(lo | hi << 8) >> 1`, negated when the low bit is set. The whole buffer
  is padded to 16 bytes, and that padded size is what was compressed.
  Each row is un-predicted against the previous row's values (zero for the
  first): 0 none, 1 Paeth (chosen on the first channel only: up when
  |up - upleft| > |left - upleft|, else left, for all three), 2 left (the same
  channel of the previous pixel), 3 up, 4 mean (`(left + up + 1) / 2`, C
  division). Then reversible YCoCg back to the stored channel order, with the
  chroma doubled when the flag is set: `t = Y - Cg/2; c1 = Cg + t;
  c2 = t - Co/2; c0 = c2 + Co`, halving toward zero. 8-bit formats keep the
  low bytes (stored order B, G, R, A); half-float formats scale by 2^(1 - depth)
  and alpha by 1/255.

## Looking things up

Apple's rules, as Apple's CoreUI answers them on macOS 26 and Finch's repeats:

- The name's facet gives the key's fixed attributes. Images may come from any
  part under the identifier (an app icon's sizes), the facet's part first.
- **Appearance** must match exactly. A name the catalog's APPEARANCEKEYS lists
  means its id; any other name, or none, means 0. So asking for
  `NSAppearanceNameDarkAqua` gets nil when the catalog has dark variants of
  something else but not of this; AppKit falls back itself: DarkAqua, then
  the default; VibrantDark through DarkAqua; VibrantLight through Aqua.
- **Scale**: the exact one, else the largest below, else the smallest above.
- **Idiom, subtype, gamut**: the requested value or 0. AppKit asks for P3 when
  the main screen can show it.
- Other attributes prefer 0.
- `imagesWithName:` lists image and data lookups (not colours or PDF vectors)
  in the tree's order; PDF vectors come from `namedVectorImageWithName:` (part 42)
  and older catalogs' `pdfDocumentWithName:` (the image's own part).

CoreUI hands out bitmaps as CGImages in RGBA order (premultiplied, alpha
skipped when the bitmap is flagged opaque), gray-alpha as gray, half-float
images with float, 16-bit little-endian components; uncompressed ARGB stays
BGRA (premultiplied first, 32-bit little-endian), as Apple's does.

## AppKit

- `+[NSColor colorNamed:]` and `colorNamed:bundle:` return an
  `NSCoreUICatalogColor` (Apple's class name), catalog
  `#$assets-mainBundleID` for the main bundle and `#$assets-<identifier>`
  for others, resolved each time it's used by the current drawing appearance
  and the screen's gamut; a system-colour reference resolves to Finch's system
  colour. They archive as Apple's (`NSColorSpace` 6 with the catalog, name and
  resolved colour), and nibs that use named colours decode to them.
- `+[NSImage imageNamed:]` looks in the main bundle's catalog before image
  files, and `-[NSBundle imageForResource:]` in that bundle's. The image has
  an `NSCoreUIImageRep` per scale, which draws the rendition for the current
  appearance. Template images are those the catalog marks, or with automatic
  rendering a name ending in `Template`. `NSImageNameApplicationIcon` is the
  app's `CFBundleIconName` image when its catalog has one.
- `NSDataAsset` reads data assets.

## Tests

- `finch-assets-test` (`userland/tests/assets-test.m`) runs as
  `AssetsTest.app`, with actool's catalogs of `assets-test.xcassets` for macOS
  26, 10.9 and 10.11 (deepmap2 in default, palette and gray forms, atlases,
  RLE, zip, uncompressed and LZFSE bitmaps), a nib using a named colour and
  image, and a second bundle. It prints CoreUI's view (every rendition's
  pixels, colours by appearance and gamut, data, lookup fallbacks, the PDF)
  and AppKit's (colours per appearance, archiving, the nib, images drawn at 1x
  and 2x in light and dark, data assets). Its 487 lines match Apple's on the
  host, all but the first, and the VM prints the same checksum.
- Against Apple's CoreUI directly, every image (pixel digests), colour and
  data lookup of the 65 catalogs in `/System/Applications` and 171 framework
  and appearance catalogs matched: about 30,500 images and 6,500 colours.
- Finch's reader's listing of Stickies, TextEdit, Calculator, Chess and Image
  Capture matches `assetutil --info`: 70 colour renditions (names,
  components, system colour names) and 141 image renditions (pixel sizes),
  every bitmap decoded.

## Not yet

DXT and other GPU-texture compressions; Apple's older palette-image and
deepmap (v1) compressions (not met in current catalogs); slice insets and
alignment for sliced images (the type is reported); icon stacks, icon groups,
named gradients, layer stacks, multisize image set objects, vector glyphs (SF
Symbols); SVG rendering; an `NSPDFImageRep` for preserved vectors (the
rasterized 1x and 2x bitmaps are used); `dataWithName:` on a PDF (Apple's
returns empty data); localized renditions; app icons in other bundles
(`NSWorkspace`); dark appearances for Finch's own system colours.
