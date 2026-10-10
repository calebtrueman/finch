/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGImageDestination: images and their properties collected until
 * CGImageDestinationFinalize writes the file (PNG, JPEG or TIFF) to a CFData, a
 * URL or a data consumer. As Apple's: finalizing with no image, or with more
 * images than the count given at creation, fails and writes nothing.
 */
#include "ImageIOInternal.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>

struct DestImage {
    CGImageRef image;
    CFDictionaryRef props;
};

struct CGImageDestination {
    IIORuntimeBase base;
    int format;  /* 0 PNG, 1 JPEG, 2 TIFF */
    size_t count;
    CFMutableDataRef data;
    CFURLRef url;
    CGDataConsumerRef consumer;
    CFDictionaryRef props;
    std::vector<DestImage> *images;
    bool finalized;
};

/*
 * Writing to a CGDataConsumer: Apple's CoreGraphics exports
 * CGDataConsumerPutBytes (privately) for this. Looked up at run time, so
 * consumer destinations fail cleanly where CoreGraphics lacks it.
 */
typedef size_t (*PutBytes)(CGDataConsumerRef, const void *, size_t);

static PutBytes
put_bytes(void)
{
    static PutBytes fn;
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, [] { fn = (PutBytes)dlsym(RTLD_DEFAULT, "CGDataConsumerPutBytes"); });
    return fn;
}

static CFTypeID dest_type_id;

static void
dest_finalize(CFTypeRef cf)
{
    CGImageDestinationRef d = (CGImageDestinationRef)cf;
    if (d->images) {
        for (DestImage &i : *d->images) {
            CGImageRelease(i.image);
            if (i.props)
                CFRelease(i.props);
        }
        delete d->images;
    }
    if (d->data)
        CFRelease(d->data);
    if (d->url)
        CFRelease(d->url);
    if (d->consumer)
        CGDataConsumerRelease(d->consumer);
    if (d->props)
        CFRelease(d->props);
}

static const IIORuntimeClass dest_class = {
    0, "CGImageDestination", NULL, NULL, dest_finalize, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};

CFTypeID
CGImageDestinationGetTypeID(void)
{
    return IIOTypeRegister(&dest_class, &dest_type_id);
}

CFArrayRef
CGImageDestinationCopyTypeIdentifiers(void)
{
    const void *v[] = {CFSTR("public.jpeg"), CFSTR("public.png"), CFSTR("public.tiff")};
    return CFArrayCreate(NULL, v, 3, &kCFTypeArrayCallBacks);
}

static CGImageDestinationRef
dest_create(CFStringRef type, size_t count)
{
    int format;
    if (!type)
        return NULL;
    if (CFEqual(type, CFSTR("public.png")))
        format = 0;
    else if (CFEqual(type, CFSTR("public.jpeg")))
        format = 1;
    else if (CFEqual(type, CFSTR("public.tiff")))
        format = 2;
    else
        return NULL;
    CGImageDestinationRef d =
        (CGImageDestinationRef)IIOTypeCreateInstance(CGImageDestinationGetTypeID(), sizeof(struct CGImageDestination));
    if (!d)
        return NULL;
    d->format = format;
    d->count = count;
    d->images = new std::vector<DestImage>;
    return d;
}

CGImageDestinationRef
CGImageDestinationCreateWithData(CFMutableDataRef data, CFStringRef type, size_t count, CFDictionaryRef options)
{
    if (!data)
        return NULL;
    CGImageDestinationRef d = dest_create(type, count);
    if (d)
        d->data = (CFMutableDataRef)CFRetain(data);
    return d;
}

CGImageDestinationRef
CGImageDestinationCreateWithURL(CFURLRef url, CFStringRef type, size_t count, CFDictionaryRef options)
{
    if (!url)
        return NULL;
    CGImageDestinationRef d = dest_create(type, count);
    if (d)
        d->url = (CFURLRef)CFRetain(url);
    return d;
}

CGImageDestinationRef
CGImageDestinationCreateWithDataConsumer(CGDataConsumerRef consumer, CFStringRef type, size_t count,
                                         CFDictionaryRef options)
{
    if (!consumer)
        return NULL;
    CGImageDestinationRef d = dest_create(type, count);
    if (d)
        d->consumer = CGDataConsumerRetain(consumer);
    return d;
}

void
CGImageDestinationSetProperties(CGImageDestinationRef d, CFDictionaryRef properties)
{
    if (!d)
        return;
    if (d->props)
        CFRelease(d->props);
    d->props = properties ? CFDictionaryCreateCopy(NULL, properties) : NULL;
}

void
CGImageDestinationAddImage(CGImageDestinationRef d, CGImageRef image, CFDictionaryRef properties)
{
    if (!d || !image || d->finalized)
        return;
    d->images->push_back({CGImageRetain(image), properties ? CFDictionaryCreateCopy(NULL, properties) : NULL});
}

void
CGImageDestinationAddImageFromSource(CGImageDestinationRef d, CGImageSourceRef isrc, size_t index,
                                     CFDictionaryRef properties)
{
    if (!d || !isrc)
        return;
    CGImageRef im = CGImageSourceCreateImageAtIndex(isrc, index, NULL);
    if (!im)
        return;
    CFDictionaryRef sp = CGImageSourceCopyPropertiesAtIndex(isrc, index, NULL);
    CFMutableDictionaryRef merged = sp ? CFDictionaryCreateMutableCopy(NULL, 0, sp)
                                       : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                   &kCFTypeDictionaryValueCallBacks);
    if (sp)
        CFRelease(sp);
    if (properties) {
        CFIndex n = CFDictionaryGetCount(properties);
        std::vector<const void *> k(n), v(n);
        CFDictionaryGetKeysAndValues(properties, k.data(), v.data());
        for (CFIndex i = 0; i < n; i++)
            CFDictionarySetValue(merged, k[i], v[i]);
    }
    CGImageDestinationAddImage(d, im, merged);
    CFRelease(merged);
    CGImageRelease(im);
}

void
CGImageDestinationAddImageAndMetadata(CGImageDestinationRef d, CGImageRef image, CGImageMetadataRef metadata,
                                      CFDictionaryRef options)
{
    CGImageDestinationAddImage(d, image, options);
}

bool
CGImageDestinationCopyImageSource(CGImageDestinationRef d, CGImageSourceRef isrc, CFDictionaryRef options,
                                  CFErrorRef *err)
{
    if (err)
        *err = NULL;
    return false;
}

void
CGImageDestinationAddAuxiliaryDataInfo(CGImageDestinationRef d, CFStringRef type, CFDictionaryRef info)
{
}

bool
CGImageDestinationFinalize(CGImageDestinationRef d)
{
    if (!d || d->finalized || d->images->empty() || d->images->size() > d->count)
        return false;
    d->finalized = true;
    std::vector<IIOEncodeOptions> opts;
    std::vector<CGImageRef> images;
    int compression = 1;
    for (DestImage &im : *d->images) {
        IIOEncodeOptions o;
        if (!IIOGetDouble(im.props, kCGImageDestinationLossyCompressionQuality, &o.quality))
            IIOGetDouble(d->props, kCGImageDestinationLossyCompressionQuality, &o.quality);
        IIOGetDouble(im.props, kCGImagePropertyDPIWidth, &o.dpi_x);
        IIOGetDouble(im.props, kCGImagePropertyDPIHeight, &o.dpi_y);
        double v;
        if (IIOGetDouble(im.props, kCGImagePropertyOrientation, &v) && v >= 1 && v <= 8)
            o.orientation = (int)v;
        CFTypeRef png = im.props ? CFDictionaryGetValue(im.props, kCGImagePropertyPNGDictionary) : NULL;
        if (png && CFGetTypeID(png) == CFDictionaryGetTypeID() &&
            IIOGetDouble((CFDictionaryRef)png, kCGImagePropertyPNGInterlaceType, &v))
            o.interlace = v != 0;
        /* TIFF's compression: {TIFF} Compression, on the image or the destination */
        for (CFDictionaryRef p : {im.props, d->props}) {
            CFTypeRef tiff = p ? CFDictionaryGetValue(p, kCGImagePropertyTIFFDictionary) : NULL;
            if (tiff && CFGetTypeID(tiff) == CFDictionaryGetTypeID() &&
                IIOGetDouble((CFDictionaryRef)tiff, kCGImagePropertyTIFFCompression, &v)) {
                compression = (int)v;
                break;
            }
        }
        opts.push_back(o);
        images.push_back(im.image);
    }
    std::vector<uint8_t> out;
    bool ok = d->format == 2   ? IIOEncodeTIFF(images, opts, compression, out)
              : d->format == 0 ? IIOEncodePNG(images[0], opts[0], out)
                               : IIOEncodeJPEG(images[0], opts[0], out);
    if (!ok)
        return false;
    if (d->data) {
        CFDataAppendBytes(d->data, out.data(), (CFIndex)out.size());
    } else if (d->consumer) {
        CGDataConsumerRef c = d->consumer;
        PutBytes put = put_bytes();
        if (!put)
            return false;
        size_t done = 0;
        while (done < out.size()) {
            size_t n = put(c, out.data() + done, out.size() - done);
            if (!n)
                return false;
            done += n;
        }
    } else if (d->url) {
        char path[PATH_MAX];
        if (!CFURLGetFileSystemRepresentation(d->url, true, (UInt8 *)path, sizeof path))
            return false;
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd < 0)
            return false;
        size_t done = 0;
        while (done < out.size()) {
            ssize_t n = write(fd, out.data() + done, out.size() - done);
            if (n <= 0)
                break;
            done += n;
        }
        close(fd);
        if (done != out.size())
            return false;
    }
    return true;
}
