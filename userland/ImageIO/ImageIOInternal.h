/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch ImageIO internals: CF runtime registration (ImageIO's types are CF
 * types, as on macOS), property-dictionary helpers, the decoded-pixel buffer
 * that becomes a CGImage, and the per-format codec interface.
 */
#ifndef IIO_INTERNAL_H
#define IIO_INTERNAL_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <stdint.h>
#include <string.h>

#ifdef __cplusplus
#include <memory>
#include <string>
#include <vector>
#endif

#define IIO_PRIVATE __attribute__((visibility("hidden")))

#ifdef __cplusplus
extern "C" {
#endif

/* Finch's CoreFoundation's runtime (swift-corelibs CFRuntime.h layout). */
typedef struct {
    uintptr_t cfisa;
    uint64_t cfinfoa;
} IIORuntimeBase;

typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef cf);
    CFTypeRef (*copy)(CFAllocatorRef allocator, CFTypeRef cf);
    void (*finalize)(CFTypeRef cf);
    Boolean (*equal)(CFTypeRef cf1, CFTypeRef cf2);
    CFHashCode (*hash)(CFTypeRef cf);
    CFStringRef (*copyFormattingDesc)(CFTypeRef cf, CFDictionaryRef formatOptions);
    CFStringRef (*copyDebugDesc)(CFTypeRef cf);
    void (*reclaim)(CFTypeRef cf);
    uint32_t (*refcount)(intptr_t op, CFTypeRef cf);
    uintptr_t requiredAlignment;
} IIORuntimeClass;

CFTypeID _CFRuntimeRegisterClass(const IIORuntimeClass *cls);
CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes,
                                   unsigned char *category);

IIO_PRIVATE CFTypeID IIOTypeRegister(const IIORuntimeClass *cls, CFTypeID *slot);
IIO_PRIVATE void *IIOTypeCreateInstance(CFTypeID type, size_t size);

#ifdef __cplusplus
}

/* ---- dictionaries, with the CFNumber types Apple's carry ---------------- */

struct IIODict {
    CFMutableDictionaryRef d;
    IIODict() : d(CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks)) {}
    ~IIODict() { if (d) CFRelease(d); }
    IIODict(const IIODict &) = delete;
    IIODict &operator=(const IIODict &) = delete;
    void set(CFStringRef k, CFTypeRef v) { if (v) { CFDictionarySetValue(d, k, v); CFRelease(v); } }
    void i32(CFStringRef k, int32_t v) { set(k, CFNumberCreate(NULL, kCFNumberSInt32Type, &v)); }
    void i64(CFStringRef k, int64_t v) { set(k, CFNumberCreate(NULL, kCFNumberSInt64Type, &v)); }
    void f32(CFStringRef k, float v) { set(k, CFNumberCreate(NULL, kCFNumberFloat32Type, &v)); }
    void f64(CFStringRef k, double v) { set(k, CFNumberCreate(NULL, kCFNumberFloat64Type, &v)); }
    void b(CFStringRef k, bool v) { CFDictionarySetValue(d, k, v ? kCFBooleanTrue : kCFBooleanFalse); }
    void str(CFStringRef k, const char *s, size_t n, CFStringEncoding enc = kCFStringEncodingUTF8)
    {
        CFStringRef v = CFStringCreateWithBytes(NULL, (const UInt8 *)s, (CFIndex)n, enc, false);
        if (!v)
            v = CFStringCreateWithBytes(NULL, (const UInt8 *)s, (CFIndex)n, kCFStringEncodingISOLatin1, false);
        set(k, v);
    }
    /* Merge a sub-dictionary in (only when it has entries). */
    void sub(CFStringRef k, IIODict &s)
    {
        if (CFDictionaryGetCount(s.d))
            CFDictionarySetValue(d, k, s.d);
    }
    CFDictionaryRef copy() const { return CFDictionaryCreateCopy(NULL, d); }
};

IIO_PRIVATE CFNumberRef IIONumberI32(int32_t v);
IIO_PRIVATE CFNumberRef IIONumberF64(double v);
IIO_PRIVATE bool IIOGetDouble(CFDictionaryRef d, CFStringRef key, double *out);
IIO_PRIVATE bool IIOGetBool(CFDictionaryRef d, CFStringRef key);

/* ---- pixels ----------------------------------------------------------- */

/* A decoded image in the layout the CGImage will have. */
struct IIOPixels {
    size_t w = 0, h = 0, bpc = 8, bpp = 32, bpr = 0;
    CGBitmapInfo info = 0;
    CGColorSpaceRef space = NULL;  /* owned */
    CGColorRenderingIntent intent = kCGRenderingIntentPerceptual;
    std::vector<uint8_t> data;

    IIOPixels() = default;
    IIOPixels(const IIOPixels &) = delete;
    IIOPixels &operator=(const IIOPixels &) = delete;
    ~IIOPixels() { if (space) CGColorSpaceRelease(space); }
    void alloc(size_t width, size_t height, size_t bits_pc, size_t bits_pp, size_t align = 1)
    {
        w = width, h = height, bpc = bits_pc, bpp = bits_pp;
        bpr = (w * bpp / 8 + align - 1) / align * align;
        data.assign(bpr * h, 0);
    }
    void set_space(CGColorSpaceRef s) { if (space) CGColorSpaceRelease(space); space = s; }
    CGImageRef image();  /* consumes data */
};

/*
 * Any CGImage's pixels as unpremultiplied doubles in [0, 1]: n colour
 * components (1 gray, 3 RGB, 4 CMYK) plus alpha (1 when it has none).
 * Indexed images come out as their base space.
 */
struct IIOFloatImage {
    size_t w = 0, h = 0, n = 0;
    bool alpha = false;
    std::vector<double> px;  /* w * h * (n + 1) */
    CGColorSpaceRef space = NULL;  /* colour space of the components (owned) */
    ~IIOFloatImage() { if (space) CGColorSpaceRelease(space); }
    double *at(size_t x, size_t y) { return &px[(y * w + x) * (n + 1)]; }
};
IIO_PRIVATE bool IIOReadImage(CGImageRef im, IIOFloatImage &out);

/* ---- colour ------------------------------------------------------------ */

IIO_PRIVATE CFStringRef IIOCopyICCDescription(const uint8_t *p, size_t n);
IIO_PRIVATE CFStringRef IIOCopyProfileName(CGColorSpaceRef cs);
IIO_PRIVATE CGColorSpaceRef IIOSpaceFromICC(const uint8_t *p, size_t n, CGColorSpaceModel want);

/* ---- EXIF (TIFF structure) --------------------------------------------- */

struct IIOExif {
    IIODict tiff, exif, gps;
    int orientation = 0;
    double xres = 0, yres = 0;
    int resunit = 0;
    int xmp_props = 0, xmp_tiff_props = 0;
    IIODict xmp_tiff;          /* xmp:ModifyDate, xmp:CreatorTool as TIFF keys */
    std::string creator_tool;  /* xmp:CreatorTool */
    std::string create_date;   /* xmp:CreateDate, as written */
};
IIO_PRIVATE bool IIOParseExif(const uint8_t *p, size_t n, IIOExif &out);
/* One IFD of a TIFF file (at byte `ifd`), and the Exif and GPS IFDs it points to. */
IIO_PRIVATE bool IIOParseTIFFIFD(const uint8_t *p, size_t n, size_t ifd, IIOExif &out);
/* XMP packets: the tiff:, exif: and xmp: properties EXIF didn't give. */
IIO_PRIVATE void IIOParseXMP(const char *p, size_t n, IIOExif &out);
/* Photoshop image resources (JPEG APP13): IPTC, and the EXIF dates it implies. */
IIO_PRIVATE void IIOParsePhotoshop(const uint8_t *p, size_t n, IIODict &iptc, IIOExif &e);
/* Apple's layout: IFD0 (Orientation, resolution) and the Exif IFD. */
IIO_PRIVATE std::vector<uint8_t> IIOMakeExif(size_t w, size_t h, bool rgb, int orientation, double dpi_x,
                                             double dpi_y);
/* Top-level DPI and Orientation from parsed EXIF. */
IIO_PRIVATE void IIOAddExif(IIODict &props, IIOExif &e, bool dpi);

/* ---- codecs ------------------------------------------------------------ */

struct IIOCodec {
    size_t count = 0;
    std::vector<bool> ready;            /* the frame's header is complete */
    std::vector<CFDictionaryRef> props; /* owned */
    CFDictionaryRef container = NULL;   /* format sub-dictionaries for CopyProperties */
    std::vector<int> orientation;

    virtual ~IIOCodec();
    void reset();
    /* (Re)read headers from the bytes so far. */
    virtual void parse(const uint8_t *p, size_t n, bool final) = 0;
    /* Decode frame i from the bytes so far (partial images are allowed). */
    virtual bool decode(size_t i, const uint8_t *p, size_t n, IIOPixels &out) = 0;
};

IIO_PRIVATE IIOCodec *IIOCodecCreatePNG();
IIO_PRIVATE IIOCodec *IIOCodecCreateJPEG();
IIO_PRIVATE IIOCodec *IIOCodecCreateGIF();
IIO_PRIVATE IIOCodec *IIOCodecCreateWebP();
IIO_PRIVATE IIOCodec *IIOCodecCreateBMP();
IIO_PRIVATE IIOCodec *IIOCodecCreateICO();
IIO_PRIVATE IIOCodec *IIOCodecCreateICNS();
IIO_PRIVATE IIOCodec *IIOCodecCreateTIFF();

/* PNG and BMP helpers shared with ICO. */
IIO_PRIVATE CFDictionaryRef IIOPNGCopyProperties(const uint8_t *p, size_t n, bool *ready, int *orientation);
IIO_PRIVATE bool IIOPNGDecode(const uint8_t *p, size_t n, IIOPixels &out);

/* Encoders (CGImageDestination). */
struct IIOEncodeOptions {
    double quality = -1;
    double dpi_x = 0, dpi_y = 0;
    int orientation = 0;
    int interlace = 0;
};
IIO_PRIVATE bool IIOEncodePNG(CGImageRef im, const IIOEncodeOptions &o, std::vector<uint8_t> &out);
IIO_PRIVATE bool IIOEncodeJPEG(CGImageRef im, const IIOEncodeOptions &o, std::vector<uint8_t> &out);
/* TIFF: one image per IFD, in Apple's layout; compression 1 (none), 5 (LZW) or 32773 (PackBits). */
IIO_PRIVATE bool IIOEncodeTIFF(const std::vector<CGImageRef> &images, const std::vector<IIOEncodeOptions> &o, int compression,
                               std::vector<uint8_t> &out);

/* Delay times, as GIF and WebP report them. */
IIO_PRIVATE void IIOAddDelay(IIODict &d, double unclamped);

#endif /* __cplusplus */

#endif
