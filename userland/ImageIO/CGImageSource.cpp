/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGImageSource: a CF type over the bytes (data, URL, provider, or
 * incremental updates), the format sniffed from them, and a codec that reads
 * properties and decodes frames. Statuses, counts and properties follow
 * Apple's for partial data: a frame's properties and image appear once its
 * header has arrived (PNG: the first IDAT; JPEG: the first scan; GIF: the
 * whole frame).
 */
#include "ImageIOInternal.h"
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

struct CGImageSource {
    IIORuntimeBase base;
    pthread_mutex_t lock;
    CFDataRef data;
    bool final;
    CFStringRef type;
    IIOCodec *codec;
    std::vector<CGImageRef> *cache;
};

static CFTypeID source_type_id;

static void
source_finalize(CFTypeRef cf)
{
    CGImageSourceRef s = (CGImageSourceRef)cf;
    delete s->codec;
    if (s->cache) {
        for (CGImageRef im : *s->cache)
            CGImageRelease(im);
        delete s->cache;
    }
    if (s->data)
        CFRelease(s->data);
    pthread_mutex_destroy(&s->lock);
}

static CFStringRef
source_desc(CFTypeRef cf)
{
    CGImageSourceRef s = (CGImageSourceRef)cf;
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<CGImageSource %p [%@]>"), cf, s->type ? s->type : CFSTR("?"));
}

static const IIORuntimeClass source_class = {
    0, "CGImageSource", NULL, NULL, source_finalize, NULL, NULL, NULL, source_desc, NULL, NULL, 0,
};

CFTypeID
CGImageSourceGetTypeID(void)
{
    return IIOTypeRegister(&source_class, &source_type_id);
}

/* ---- formats -------------------------------------------------------------- */

static const struct Format {
    const char *uti;
    IIOCodec *(*create)();
} formats[] = {
    {"public.jpeg", IIOCodecCreateJPEG},     {"public.png", IIOCodecCreatePNG},
    {"com.compuserve.gif", IIOCodecCreateGIF}, {"com.microsoft.ico", IIOCodecCreateICO},
    {"com.microsoft.bmp", IIOCodecCreateBMP}, {"org.webmproject.webp", IIOCodecCreateWebP},
};

static CFStringRef
uti_string(int i)
{
    static CFStringRef strings[6];
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, [] {
        for (int k = 0; k < 6; k++)
            strings[k] = CFStringCreateWithCString(NULL, formats[k].uti, kCFStringEncodingASCII);
    });
    return strings[i];
}

static int
sniff(const uint8_t *p, size_t n)
{
    static const uint8_t png[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    if (n >= 3 && p[0] == 0xff && p[1] == 0xd8 && p[2] == 0xff)
        return 0;
    if (n >= 12 && !memcmp(p, png, 8))
        return 1;
    if (n >= 13 && (!memcmp(p, "GIF87a", 6) || !memcmp(p, "GIF89a", 6)))
        return 2;
    if (n >= 22 && p[0] == 0 && p[1] == 0 && p[2] == 1 && p[3] == 0 && (p[4] | p[5] << 8) > 0 && p[9] == 0)
        return 3;
    if (n >= 18 && p[0] == 'B' && p[1] == 'M') {
        uint32_t hs = p[14] | p[15] << 8 | p[16] << 16 | (uint32_t)p[17] << 24;
        if (hs == 12 || hs == 40 || hs == 52 || hs == 56 || hs == 64 || hs == 108 || hs == 124)
            return 4;
    }
    if (n >= 16 && !memcmp(p, "RIFF", 4) && !memcmp(p + 8, "WEBPVP8", 7))
        return 5;
    return -1;
}

/* Called with the lock held after the bytes change. */
static void
update(CGImageSourceRef s)
{
    const uint8_t *p = s->data ? CFDataGetBytePtr(s->data) : NULL;
    size_t n = s->data ? (size_t)CFDataGetLength(s->data) : 0;
    if (!s->type) {
        int f = n ? sniff(p, n) : -1;
        if (f < 0)
            return;
        s->type = uti_string(f);
        s->codec = formats[f].create();
    }
    s->codec->parse(p, n, s->final);
    for (CGImageRef im : *s->cache)
        if (im)
            CGImageRelease(im);
    s->cache->assign(s->codec->count, NULL);
}

static CGImageSourceRef
source_create(CFDataRef data, bool final)
{
    CGImageSourceRef s = (CGImageSourceRef)IIOTypeCreateInstance(CGImageSourceGetTypeID(), sizeof(struct CGImageSource));
    if (!s)
        return NULL;
    pthread_mutex_init(&s->lock, NULL);
    s->data = data;
    s->final = final;
    s->cache = new std::vector<CGImageRef>;
    update(s);
    return s;
}

CFArrayRef
CGImageSourceCopyTypeIdentifiers(void)
{
    const void *v[6];
    for (int i = 0; i < 6; i++)
        v[i] = uti_string(i);
    return CFArrayCreate(NULL, v, 6, &kCFTypeArrayCallBacks);
}

CGImageSourceRef
CGImageSourceCreateWithData(CFDataRef data, CFDictionaryRef options)
{
    if (!data)
        return NULL;
    return source_create(CFDataCreateCopy(NULL, data), true);
}

CGImageSourceRef
CGImageSourceCreateWithDataProvider(CGDataProviderRef provider, CFDictionaryRef options)
{
    if (!provider)
        return NULL;
    CFDataRef d = CGDataProviderCopyData(provider);
    return source_create(d ? d : CFDataCreate(NULL, NULL, 0), true);
}

static CFDataRef
read_url(CFURLRef url)
{
    char path[PATH_MAX];
    if (!url || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path))
        return NULL;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return NULL;
    struct stat st;
    CFMutableDataRef d = NULL;
    if (!fstat(fd, &st) && S_ISREG(st.st_mode)) {
        d = CFDataCreateMutable(NULL, 0);
        CFDataSetLength(d, st.st_size);
        size_t got = 0;
        while (got < (size_t)st.st_size) {
            ssize_t r = read(fd, CFDataGetMutableBytePtr(d) + got, st.st_size - got);
            if (r <= 0)
                break;
            got += r;
        }
        CFDataSetLength(d, got);
    }
    close(fd);
    return d;
}

CGImageSourceRef
CGImageSourceCreateWithURL(CFURLRef url, CFDictionaryRef options)
{
    if (!url)
        return NULL;
    CFDataRef d = read_url(url);
    return source_create(d ? d : CFDataCreate(NULL, NULL, 0), true);
}

CGImageSourceRef
CGImageSourceCreateIncremental(CFDictionaryRef options)
{
    return source_create(NULL, false);
}

void
CGImageSourceUpdateData(CGImageSourceRef s, CFDataRef data, bool final)
{
    if (!s || !data)
        return;
    pthread_mutex_lock(&s->lock);
    if (s->data)
        CFRelease(s->data);
    s->data = CFDataCreateCopy(NULL, data);
    s->final = final;
    update(s);
    pthread_mutex_unlock(&s->lock);
}

void
CGImageSourceUpdateDataProvider(CGImageSourceRef s, CGDataProviderRef provider, bool final)
{
    if (!s || !provider)
        return;
    CFDataRef d = CGDataProviderCopyData(provider);
    if (d) {
        CGImageSourceUpdateData(s, d, final);
        CFRelease(d);
    }
}

CFStringRef
CGImageSourceGetType(CGImageSourceRef s)
{
    return s ? s->type : NULL;
}

size_t
CGImageSourceGetCount(CGImageSourceRef s)
{
    if (!s)
        return 0;
    pthread_mutex_lock(&s->lock);
    size_t n = s->codec ? s->codec->count : 0;
    pthread_mutex_unlock(&s->lock);
    return n;
}

size_t
CGImageSourceGetPrimaryImageIndex(CGImageSourceRef s)
{
    return 0;
}

static size_t
data_length(CGImageSourceRef s)
{
    return s->data ? (size_t)CFDataGetLength(s->data) : 0;
}

CGImageSourceStatus
CGImageSourceGetStatus(CGImageSourceRef s)
{
    if (!s)
        return kCGImageStatusInvalidData;
    pthread_mutex_lock(&s->lock);
    CGImageSourceStatus st = !s->type || !data_length(s) ? kCGImageStatusInvalidData
                             : s->final                 ? kCGImageStatusComplete
                                                        : kCGImageStatusIncomplete;
    pthread_mutex_unlock(&s->lock);
    return st;
}

CGImageSourceStatus
CGImageSourceGetStatusAtIndex(CGImageSourceRef s, size_t i)
{
    if (!s)
        return kCGImageStatusInvalidData;
    pthread_mutex_lock(&s->lock);
    CGImageSourceStatus st;
    if (!s->type)
        st = data_length(s) < 8 ? kCGImageStatusReadingHeader : kCGImageStatusUnknownType;
    else if (i < s->codec->count)
        st = s->final || s->codec->ready[i] ? kCGImageStatusComplete : kCGImageStatusIncomplete;
    else
        st = !s->codec->count && !s->final ? kCGImageStatusIncomplete : kCGImageStatusInvalidData;
    pthread_mutex_unlock(&s->lock);
    return st;
}

CFDictionaryRef
CGImageSourceCopyProperties(CGImageSourceRef s, CFDictionaryRef options)
{
    if (!s)
        return NULL;
    pthread_mutex_lock(&s->lock);
    CFDictionaryRef r = NULL;
    if (s->type) {
        IIODict d;
        d.i64(kCGImagePropertyFileSize, (int64_t)data_length(s));
        if (s->codec->container) {
            CFIndex n = CFDictionaryGetCount(s->codec->container);
            std::vector<const void *> k(n), v(n);
            CFDictionaryGetKeysAndValues(s->codec->container, k.data(), v.data());
            for (CFIndex i = 0; i < n; i++)
                CFDictionarySetValue(d.d, k[i], v[i]);
        }
        r = d.copy();
    }
    pthread_mutex_unlock(&s->lock);
    return r;
}

CFDictionaryRef
CGImageSourceCopyPropertiesAtIndex(CGImageSourceRef s, size_t i, CFDictionaryRef options)
{
    if (!s)
        return NULL;
    pthread_mutex_lock(&s->lock);
    CFDictionaryRef r = NULL;
    if (s->codec && i < s->codec->count) {
        if (s->codec->ready[i] && s->codec->props[i])
            r = (CFDictionaryRef)CFRetain(s->codec->props[i]);
        else
            r = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    pthread_mutex_unlock(&s->lock);
    return r;
}

CGImageMetadataRef
CGImageSourceCopyMetadataAtIndex(CGImageSourceRef s, size_t i, CFDictionaryRef options)
{
    return NULL;
}

CFDictionaryRef
CGImageSourceCopyAuxiliaryDataInfoAtIndex(CGImageSourceRef s, size_t i, CFStringRef type)
{
    return NULL;
}

OSStatus
CGImageSourceSetAllowableTypes(CFArrayRef types)
{
    return 0;
}

CGImageRef
CGImageSourceCreateImageAtIndex(CGImageSourceRef s, size_t i, CFDictionaryRef options)
{
    if (!s)
        return NULL;
    pthread_mutex_lock(&s->lock);
    CGImageRef im = NULL;
    if (s->codec && i < s->codec->count && s->codec->ready[i]) {
        if ((*s->cache)[i]) {
            im = CGImageRetain((*s->cache)[i]);
        } else {
            IIOPixels px;
            if (s->codec->decode(i, CFDataGetBytePtr(s->data), data_length(s), px) && px.space)
                im = px.image();
            if (im && s->final)
                (*s->cache)[i] = CGImageRetain(im);
        }
    }
    pthread_mutex_unlock(&s->lock);
    return im;
}

void
CGImageSourceRemoveCacheAtIndex(CGImageSourceRef s, size_t i)
{
    if (!s)
        return;
    pthread_mutex_lock(&s->lock);
    if (i < s->cache->size() && (*s->cache)[i]) {
        CGImageRelease((*s->cache)[i]);
        (*s->cache)[i] = NULL;
    }
    pthread_mutex_unlock(&s->lock);
}

/* ---- thumbnails -------------------------------------------------------------- */

/* Source pixel of oriented pixel (x, y), for an image W x H before orienting. */
static void
orient_src(int o, size_t x, size_t y, size_t W, size_t H, size_t *sx, size_t *sy)
{
    switch (o) {
    case 2: *sx = W - 1 - x, *sy = y; break;
    case 3: *sx = W - 1 - x, *sy = H - 1 - y; break;
    case 4: *sx = x, *sy = H - 1 - y; break;
    case 5: *sx = y, *sy = x; break;
    case 6: *sx = y, *sy = H - 1 - x; break;
    case 7: *sx = W - 1 - y, *sy = H - 1 - x; break;
    case 8: *sx = W - 1 - y, *sy = x; break;
    default: *sx = x, *sy = y; break;
    }
}

static double
sinc(double x)
{
    return x == 0 ? 1 : sin(M_PI * x) / (M_PI * x);
}

/*
 * Resample along x (horizontal) or y to `to` samples. Pixel centres map to
 * pixel centres; the filter widens with the reduction, as Apple's thumbnails
 * look (their scaler is not documented; this one agrees within a few levels
 * on smooth images).
 */
static std::vector<double>
resample(const std::vector<double> &src, size_t w, size_t h, size_t nc, size_t to, bool horizontal)
{
    size_t from = horizontal ? w : h;
    size_t ow = horizontal ? to : w, oh = horizontal ? h : to;
    std::vector<double> out(ow * oh * nc, 0);
    double scale = (double)from / to, f = scale > 1 ? scale * 1.3 : 1, support = 3 * f;
    for (size_t j = 0; j < to; j++) {
        double p = (j + 0.5) * scale - 0.5;
        long lo = (long)floor(p - support), hi = (long)ceil(p + support);
        std::vector<std::pair<size_t, double>> taps;
        double total = 0;
        for (long i = lo; i <= hi; i++) {
            double x = (i - p) / f;
            if (fabs(x) >= 3)
                continue;
            double wgt = sinc(x) * sinc(x / 3);
            long c = i < 0 ? 0 : i >= (long)from ? (long)from - 1 : i;
            taps.push_back({(size_t)c, wgt});
            total += wgt;
        }
        for (size_t o = 0; o < (horizontal ? h : w); o++) {
            double *d = horizontal ? &out[(o * ow + j) * nc] : &out[(j * ow + o) * nc];
            for (auto &t : taps) {
                const double *sp = horizontal ? &src[(o * w + t.first) * nc] : &src[(t.first * w + o) * nc];
                for (size_t k = 0; k < nc; k++)
                    d[k] += sp[k] * t.second / total;
            }
        }
    }
    return out;
}

CGImageRef
CGImageSourceCreateThumbnailAtIndex(CGImageSourceRef s, size_t i, CFDictionaryRef options)
{
    if (!s)
        return NULL;
    bool always = IIOGetBool(options, kCGImageSourceCreateThumbnailFromImageAlways);
    bool transform = IIOGetBool(options, kCGImageSourceCreateThumbnailWithTransform);
    double maxd = 0;
    IIOGetDouble(options, kCGImageSourceThumbnailMaxPixelSize, &maxd);
    size_t max = maxd > 0 ? (size_t)maxd : 0;
    if (always && !max && !transform)
        return CGImageSourceCreateImageAtIndex(s, i, NULL);
    int orientation = 1;
    pthread_mutex_lock(&s->lock);
    if (s->codec && i < s->codec->orientation.size() && s->codec->orientation[i])
        orientation = s->codec->orientation[i];
    pthread_mutex_unlock(&s->lock);
    if (!transform)
        orientation = 1;

    CGImageRef full = CGImageSourceCreateImageAtIndex(s, i, NULL);
    if (!full)
        return NULL;
    IIOFloatImage f;
    bool ok = IIOReadImage(full, f);
    size_t src_bpc = CGImageGetBitsPerComponent(full);
    CGImageRelease(full);
    if (!ok || (f.n != 1 && f.n != 3))
        return NULL;

    size_t W = f.w, H = f.h;
    size_t ow = orientation >= 5 ? H : W, oh = orientation >= 5 ? W : H;
    size_t tw = ow, th = oh;
    size_t L = ow > oh ? ow : oh;
    if (max && max < L) {
        if (ow >= oh)
            tw = max, th = (size_t)lround((double)oh * max / ow);
        else
            th = max, tw = (size_t)lround((double)ow * max / oh);
        if (!tw)
            tw = 1;
        if (!th)
            th = 1;
    }

    /* The oriented image, premultiplied. */
    size_t nc = f.n + 1;
    std::vector<double> img(ow * oh * nc);
    for (size_t y = 0; y < oh; y++)
        for (size_t x = 0; x < ow; x++) {
            size_t px, py;
            orient_src(orientation, x, y, W, H, &px, &py);
            double *v = f.at(px, py), *o = &img[(y * ow + x) * nc], al = v[f.n];
            for (size_t k = 0; k < f.n; k++)
                o[k] = v[k] * al;
            o[f.n] = al;
        }
    /* Scaled with a widened Lanczos-3 filter, rows then columns. */
    std::vector<double> rows = resample(img, ow, oh, nc, tw, true);
    std::vector<double> acc = resample(rows, tw, oh, nc, th, false);
    for (size_t p = 0; p < tw * th; p++) {
        double *a = &acc[p * nc], al = a[f.n];
        if (al <= 0)
            for (size_t k = 0; k < nc; k++)
                a[k] = 0;
    }

    IIOPixels out;
    out.intent = kCGRenderingIntentDefault;
    bool gray = f.n == 1;
    bool sixteen = src_bpc == 16 && !f.alpha && !gray;
    if (gray && !f.alpha) {
        out.alloc(tw, th, 8, 8, 16);
        out.info = kCGImageAlphaNone;
    } else if (gray) {
        out.alloc(tw, th, 8, 16, 16);
        out.info = kCGImageAlphaPremultipliedFirst;
    } else if (sixteen) {
        out.alloc(tw, th, 16, 64, 16);
        out.info = kCGBitmapByteOrder16Little | kCGImageAlphaNoneSkipLast;
    } else if (f.alpha) {
        out.alloc(tw, th, 8, 32, 16);
        out.info = kCGImageAlphaPremultipliedFirst;
    } else {
        out.alloc(tw, th, 8, 32, 16);
        out.info = kCGImageAlphaNoneSkipFirst;
    }
    for (size_t y = 0; y < th; y++) {
        uint8_t *row = &out.data[y * out.bpr];
        for (size_t x = 0; x < tw; x++) {
            double *a = &acc[(y * tw + x) * nc];
            auto q8 = [](double v) { return (uint8_t)lround((v < 0 ? 0 : v > 1 ? 1 : v) * 255); };
            if (gray && !f.alpha) {
                row[x] = q8(a[0]);
            } else if (gray) {
                row[2 * x] = q8(a[1]), row[2 * x + 1] = q8(a[0]);
            } else if (sixteen) {
                for (int k = 0; k < 4; k++) {
                    double v = k < 3 ? a[k] : 1;
                    unsigned u = (unsigned)lround((v < 0 ? 0 : v > 1 ? 1 : v) * 65535);
                    row[8 * x + 2 * k] = (uint8_t)u, row[8 * x + 2 * k + 1] = (uint8_t)(u >> 8);
                }
            } else if (f.alpha) {
                row[4 * x] = q8(a[3]);
                for (int k = 0; k < 3; k++)
                    row[4 * x + 1 + k] = q8(a[k]);
            } else {
                row[4 * x] = 0xff;
                for (int k = 0; k < 3; k++)
                    row[4 * x + 1 + k] = q8(a[k]);
            }
        }
    }
    out.set_space(CGColorSpaceRetain(f.space));
    return out.image();
}
