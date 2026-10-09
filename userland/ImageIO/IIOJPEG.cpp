/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * JPEG over libjpeg-turbo: properties from the markers before the first scan
 * (JFIF, Exif, ICC profile, frame header), pixels as Apple's ImageIO lays
 * them out (RGBX with kCGImageAlphaNoneSkipLast, 8-bit gray, CMYK), and the
 * encoder with Apple's markers (JFIF, Exif, an ICC profile for non-sRGB).
 */
#include "ImageIOInternal.h"
#include <math.h>
#include <setjmp.h>
#include <stdio.h>
#include <string>
#include <jpeglib.h>

namespace {

struct Header {
    bool sof = false, progressive = false, ready = false, adobe = false;
    int precision = 8, ncomp = 0, adobe_transform = -1;
    uint32_t w = 0, h = 0;
    bool jfif = false;
    int jfif_major = 0, jfif_minor = 0, density_unit = 0, xdensity = 0, ydensity = 0;
    std::vector<uint8_t> exif;
    std::string xmp;
    std::vector<uint8_t> photoshop;
    std::vector<std::vector<uint8_t>> icc;  /* by sequence number */
    size_t segments = 0;
};

void
read_header(const uint8_t *p, size_t n, Header &h)
{
    if (n < 2 || p[0] != 0xff || p[1] != 0xd8)
        return;
    size_t o = 2;
    while (o + 4 <= n) {
        if (p[o] != 0xff) {
            o++;
            continue;
        }
        uint8_t m = p[o + 1];
        if (m == 0xff) {
            o++;
            continue;
        }
        if (m == 0xd8 || (m >= 0xd0 && m <= 0xd7) || m == 0x01) {
            o += 2;
            continue;
        }
        size_t len = (size_t)p[o + 2] << 8 | p[o + 3];
        if (m == 0xda) {
            h.ready = h.sof;
            return;
        }
        if (len < 2 || o + 2 + len > n)
            return;
        const uint8_t *d = p + o + 4;
        size_t dl = len - 2;
        h.segments++;
        if (m == 0xe0 && dl >= 14 && !memcmp(d, "JFIF", 5)) {
            h.jfif = true;
            h.jfif_major = d[5], h.jfif_minor = d[6], h.density_unit = d[7];
            h.xdensity = d[8] << 8 | d[9], h.ydensity = d[10] << 8 | d[11];
        } else if (m == 0xe1 && dl >= 6 && !memcmp(d, "Exif\0\0", 6) && h.exif.empty()) {
            h.exif.assign(d + 6, d + dl);
        } else if (m == 0xe1 && dl >= 29 && !memcmp(d, "http://ns.adobe.com/xap/1.0/", 29)) {
            h.xmp.assign((const char *)d + 29, dl - 29);
        } else if (m == 0xed && dl >= 14 && !memcmp(d, "Photoshop 3.0", 14)) {
            h.photoshop.insert(h.photoshop.end(), d + 14, d + dl);
        } else if (m == 0xe2 && dl >= 14 && !memcmp(d, "ICC_PROFILE", 12)) {
            int seq = d[12];
            if (seq >= 1) {
                if (h.icc.size() < (size_t)seq)
                    h.icc.resize(seq);
                h.icc[seq - 1].assign(d + 14, d + dl);
            }
        } else if (m == 0xee && dl >= 12 && !memcmp(d, "Adobe", 5)) {
            h.adobe = true, h.adobe_transform = d[11];
        } else if (m >= 0xc0 && m <= 0xcf && m != 0xc4 && m != 0xc8 && m != 0xcc && dl >= 6) {
            h.sof = true;
            h.progressive = m == 0xc2 || m == 0xc6 || m == 0xca || m == 0xce;
            h.precision = d[0];
            h.h = (uint32_t)(d[1] << 8 | d[2]), h.w = (uint32_t)(d[3] << 8 | d[4]);
            h.ncomp = d[5];
        }
        o += 2 + len;
    }
}

std::vector<uint8_t>
icc_of(const Header &h)
{
    std::vector<uint8_t> all;
    for (const auto &part : h.icc) {
        if (part.empty())
            return {};
        all.insert(all.end(), part.begin(), part.end());
    }
    return all;
}

CGColorSpaceModel
model_of(const Header &h)
{
    return h.ncomp == 1 ? kCGColorSpaceModelMonochrome : h.ncomp == 4 ? kCGColorSpaceModelCMYK : kCGColorSpaceModelRGB;
}

CGColorSpaceRef
jpeg_space(const Header &h)
{
    std::vector<uint8_t> icc = icc_of(h);
    if (!icc.empty()) {
        CGColorSpaceRef cs = IIOSpaceFromICC(icc.data(), icc.size(), model_of(h));
        if (cs)
            return cs;
    }
    switch (model_of(h)) {
    case kCGColorSpaceModelMonochrome: return CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    case kCGColorSpaceModelCMYK: return CGColorSpaceCreateDeviceCMYK();
    default: return CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    }
}

struct JPEGCodec : IIOCodec {
    void parse(const uint8_t *p, size_t n, bool final) override
    {
        reset();
        Header h;
        read_header(p, n, h);
        if (!h.segments && !h.ready && !final)
            return;
        count = 1;
        ready.push_back(h.ready);
        orientation.push_back(0);
        if (!h.ready) {
            props.push_back(NULL);
            return;
        }
        IIODict d, jfif;
        CGColorSpaceModel model = model_of(h);
        d.str(kCGImagePropertyColorModel, model == kCGColorSpaceModelMonochrome ? "Gray" : model == kCGColorSpaceModelCMYK ? "CMYK" : "RGB",
              model == kCGColorSpaceModelRGB ? 3 : 4);
        d.i64(kCGImagePropertyDepth, h.precision);
        d.i64(kCGImagePropertyPixelWidth, h.w);
        d.i64(kCGImagePropertyPixelHeight, h.h);
        std::vector<uint8_t> icc = icc_of(h);
        CFStringRef name = icc.empty() ? NULL : IIOCopyICCDescription(icc.data(), icc.size());
        if (!name && model != kCGColorSpaceModelCMYK) {
            CGColorSpaceRef cs = jpeg_space(h);
            name = IIOCopyProfileName(cs);
            CGColorSpaceRelease(cs);
        }
        d.set(kCGImagePropertyProfileName, name);
        if (h.jfif) {
            CFMutableArrayRef v = CFArrayCreateMutable(NULL, 3, &kCFTypeArrayCallBacks);
            int parts[3] = {h.jfif_major, h.jfif_minor / 10, h.jfif_minor % 10};
            for (int k = 0; k < 3; k++) {
                CFNumberRef num = IIONumberI32(parts[k]);
                CFArrayAppendValue(v, num);
                CFRelease(num);
            }
            jfif.set(kCGImagePropertyJFIFVersion, v);
            jfif.i32(kCGImagePropertyJFIFDensityUnit, h.density_unit);
            jfif.i32(kCGImagePropertyJFIFXDensity, h.xdensity);
            jfif.i32(kCGImagePropertyJFIFYDensity, h.ydensity);
        }
        if (h.progressive)
            jfif.b(kCGImagePropertyJFIFIsProgressive, true);
        IIOExif e;
        bool have_exif = !h.exif.empty() && IIOParseExif(h.exif.data(), h.exif.size(), e);
        if (!h.xmp.empty()) {
            IIOParseXMP(h.xmp.data(), h.xmp.size(), e);
            have_exif = true;
        }
        IIODict iptc;
        if (!h.photoshop.empty()) {
            IIOParsePhotoshop(h.photoshop.data(), h.photoshop.size(), iptc, e);
            have_exif = true;
        }
        d.sub(kCGImagePropertyIPTCDictionary, iptc);
        bool dpi = false;
        if (have_exif) {
            IIOAddExif(d, e, true);
            orientation[0] = e.orientation;
            dpi = CFDictionaryContainsKey(d.d, kCGImagePropertyDPIWidth);
        }
        if (!dpi && h.jfif && (h.density_unit == 1 || h.density_unit == 2) && h.xdensity && h.ydensity) {
            double k = h.density_unit == 2 ? 2.54 : 1;
            d.f32(kCGImagePropertyDPIWidth, (float)(h.xdensity * k));
            d.f32(kCGImagePropertyDPIHeight, (float)(h.ydensity * k));
        }
        d.sub(kCGImagePropertyJFIFDictionary, jfif);
        props.push_back(d.copy());
    }

    bool decode(size_t i, const uint8_t *p, size_t n, IIOPixels &out) override;
};

struct ErrorMgr {
    jpeg_error_mgr pub;
    jmp_buf jb;
};

void
error_exit(j_common_ptr cinfo)
{
    longjmp(((ErrorMgr *)cinfo->err)->jb, 1);
}

void
emit_message(j_common_ptr, int)
{
}

bool
JPEGCodec::decode(size_t i, const uint8_t *p, size_t n, IIOPixels &out)
{
    Header h;
    read_header(p, n, h);
    if (!h.ready || !h.w || !h.h || (uint64_t)h.w * h.h > (1u << 28))
        return false;
    jpeg_decompress_struct cinfo;
    ErrorMgr err;
    cinfo.err = jpeg_std_error(&err.pub);
    err.pub.error_exit = error_exit;
    err.pub.emit_message = emit_message;
    volatile bool started = false;
    if (setjmp(err.jb)) {
        jpeg_destroy_decompress(&cinfo);
        return started;
    }
    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, p, (unsigned long)n);
    if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK) {
        jpeg_destroy_decompress(&cinfo);
        return false;
    }
    size_t bpp;
    CGBitmapInfo bi;
    bool invert = false;
    if (cinfo.num_components == 1) {
        cinfo.out_color_space = JCS_GRAYSCALE;
        bpp = 8, bi = kCGImageAlphaNone;
    } else if (cinfo.num_components == 4) {
        cinfo.out_color_space = JCS_CMYK;
        invert = h.adobe;
        bpp = 32, bi = kCGImageAlphaNone;
    } else {
        cinfo.out_color_space = JCS_EXT_RGBX;
        bpp = 32, bi = kCGImageAlphaNoneSkipLast;
    }
    cinfo.dct_method = JDCT_ISLOW;
    /* Apple's decoder smooths 4:2:0 chroma, but replicates 4:2:2's */
    cinfo.do_fancy_upsampling = !(cinfo.max_h_samp_factor == 2 && cinfo.max_v_samp_factor == 1);
    jpeg_start_decompress(&cinfo);
    out.alloc(cinfo.output_width, cinfo.output_height, 8, bpp);
    out.info = bi;
    if (bpp == 32 && !invert && cinfo.num_components == 3)
        for (size_t k = 3; k < out.data.size(); k += 4)
            out.data[k] = 0xff;
    out.set_space(jpeg_space(h));
    started = true;
    while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW row = out.data.data() + cinfo.output_scanline * out.bpr;
        jpeg_read_scanlines(&cinfo, &row, 1);
    }
    if (invert)
        for (uint8_t &b : out.data)
            b = 255 - b;
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    return true;
}

} // namespace

IIOCodec *
IIOCodecCreateJPEG()
{
    return new JPEGCodec;
}

/*
 * ImageIO's quality (0-1) as libjpeg's (1-100), so the quantization is
 * close to Apple's: measured from the tables Apple's encoder writes (its
 * default, 0.75, matches libjpeg's 92).
 */
static int
libjpeg_quality(double q)
{
    static const double qs[] = {0, 0.1, 0.3, 0.5, 0.6, 0.7, 0.75, 0.8, 0.85, 0.95, 1.0};
    static const double Q[] = {1, 22, 42, 78, 85, 90, 92, 93, 94, 96, 100};
    if (!(q > 0))
        return 1;
    if (q >= 1)
        return 100;
    size_t i = 1;
    while (qs[i] < q)
        i++;
    double t = (q - qs[i - 1]) / (qs[i] - qs[i - 1]);
    return (int)lround(Q[i - 1] + t * (Q[i] - Q[i - 1]));
}

bool
IIOEncodeJPEG(CGImageRef im, const IIOEncodeOptions &opt, std::vector<uint8_t> &out)
{
    IIOFloatImage f;
    if (!IIOReadImage(im, f) || (f.n != 1 && f.n != 3))
        return false;
    size_t w = f.w, h = f.h, nc = f.n;
    std::vector<uint8_t> px(w * h * nc);
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w; x++) {
            double *s = f.at(x, y);
            for (size_t k = 0; k < nc; k++) {
                double v = s[k];
                v = v < 0 ? 0 : v > 1 ? 1 : v;
                px[(y * w + x) * nc + k] = (uint8_t)lround(v * 255);
            }
        }
    jpeg_compress_struct cinfo;
    ErrorMgr err;
    cinfo.err = jpeg_std_error(&err.pub);
    err.pub.error_exit = error_exit;
    err.pub.emit_message = emit_message;
    unsigned char *buf = NULL;
    unsigned long size = 0;
    if (setjmp(err.jb)) {
        jpeg_destroy_compress(&cinfo);
        free(buf);
        return false;
    }
    jpeg_create_compress(&cinfo);
    jpeg_mem_dest(&cinfo, &buf, &size);
    cinfo.image_width = (JDIMENSION)w;
    cinfo.image_height = (JDIMENSION)h;
    cinfo.input_components = (int)nc;
    cinfo.in_color_space = nc == 1 ? JCS_GRAYSCALE : JCS_RGB;
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, libjpeg_quality(opt.quality < 0 ? 0.75 : opt.quality), TRUE);
    cinfo.write_JFIF_header = TRUE;
    cinfo.JFIF_major_version = 1, cinfo.JFIF_minor_version = 1;
    cinfo.density_unit = 0;
    bool dpi = opt.dpi_x > 0 && opt.dpi_y > 0;
    cinfo.X_density = (UINT16)(dpi ? lround(opt.dpi_x) : 72);
    cinfo.Y_density = (UINT16)(dpi ? lround(opt.dpi_y) : 72);
    cinfo.dct_method = JDCT_ISLOW;
    jpeg_start_compress(&cinfo, TRUE);
    std::vector<uint8_t> exif = IIOMakeExif(w, h, nc == 3, opt.orientation, opt.dpi_x, opt.dpi_y);
    exif.insert(exif.begin(), {'E', 'x', 'i', 'f', 0, 0});
    jpeg_write_marker(&cinfo, JPEG_APP0 + 1, exif.data(), (unsigned)exif.size());
    CGColorSpaceRef cs = f.space;
    CFStringRef name = CGColorSpaceGetName(cs);
    if (!(name && CFEqual(name, kCGColorSpaceSRGB))) {
        CFDataRef icc = CGColorSpaceCopyICCData(cs);
        if (icc) {
            jpeg_write_icc_profile(&cinfo, CFDataGetBytePtr(icc), (unsigned)CFDataGetLength(icc));
            CFRelease(icc);
        }
    }
    while (cinfo.next_scanline < cinfo.image_height) {
        JSAMPROW row = &px[cinfo.next_scanline * w * nc];
        jpeg_write_scanlines(&cinfo, &row, 1);
    }
    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    out.assign(buf, buf + size);
    free(buf);
    return true;
}
