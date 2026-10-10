/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-colorsync-test: ColorSync profiles and transforms, one result per line so runs
 * against Apple's ColorSync and Finch's can be diffed. It prints the named profiles'
 * descriptions and kinds, conversions between them (floats to two places, 8-bit
 * values exactly, with each alpha layout), and what a profile made from ICC bytes
 * reports: its header, tags, MD5 and edits.
 */
#include <ColorSync/ColorSync.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static void
print_string(const char *label, CFStringRef s)
{
    char b[256] = "(null)";
    if (s)
        CFStringGetCString(s, b, sizeof b, kCFStringEncodingUTF8);
    printf("%s: %s\n", label, b);
}

static ColorSyncTransformRef
make(ColorSyncProfileRef a, ColorSyncProfileRef b)
{
    const void *keys[] = {kColorSyncProfile, kColorSyncRenderingIntent, kColorSyncTransformTag};
    const void *va[] = {a, kColorSyncRenderingIntentPerceptual, kColorSyncTransformDeviceToPCS};
    const void *vb[] = {b, kColorSyncRenderingIntentPerceptual, kColorSyncTransformPCSToDevice};
    CFDictionaryRef da = CFDictionaryCreate(NULL, keys, va, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryRef db = CFDictionaryCreate(NULL, keys, vb, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *seq[] = {da, db};
    CFArrayRef s = CFArrayCreate(NULL, seq, 2, &kCFTypeArrayCallBacks);
    ColorSyncTransformRef t = ColorSyncTransformCreate(s, NULL);
    CFRelease(s);
    CFRelease(da);
    CFRelease(db);
    return t;
}

static ColorSyncTransformRef
make_named(CFStringRef from, CFStringRef to)
{
    ColorSyncProfileRef a = ColorSyncProfileCreateWithName(from), b = ColorSyncProfileCreateWithName(to);
    ColorSyncTransformRef t = make(a, b);
    CFRelease(a);
    CFRelease(b);
    return t;
}

static const float kColors[][3] = {{0, 0, 0}, {1, 1, 1}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1},
                                   {0.5f, 0.5f, 0.5f}, {0.2f, 0.4f, 0.8f}, {0.9f, 0.85f, 0.1f}};
/* Lab colors, as ColorSync's floats carry them (L/100, a/255 + 0.5, b/255 + 0.5) */
static const float kLabColors[][3] = {{0, 0.5f, 0.5f}, {1, 0.5f, 0.5f}, {0.5f, 0.5f, 0.5f}, {0.53f, 0.81f, 0.76f},
                                      {0.6f, 0.34f, 0.62f}, {0.3f, 0.58f, 0.26f}, {0.8f, 0.45f, 0.9f},
                                      {0.25f, 0.7f, 0.3f}};

static void
convert_list(const char *label, ColorSyncTransformRef t, int nin, int nout, const float colors[][3])
{
    for (int c = 0; c < 8; c++) {
        float out[3] = {0};
        bool ok = ColorSyncTransformConvert(t, 1, 1, out, kColorSync32BitFloat, 0, (size_t)(4 * nout), colors[c],
                                            kColorSync32BitFloat, 0, (size_t)(4 * nin), NULL);
        printf("%s (%.2f %.2f %.2f) %d:", label, colors[c][0], colors[c][1], colors[c][2], ok);
        for (int k = 0; k < nout; k++)
            printf(" %.2f", out[k] > -0.005f && out[k] < 0.005f ? 0.0f : out[k]);
        printf("\n");
    }
}

static void
convert_floats(const char *label, ColorSyncTransformRef t, int nin, int nout)
{
    convert_list(label, t, nin, nout, kColors);
}

static void
convert8(const char *label, ColorSyncTransformRef t, const unsigned char *in, ColorSyncDataLayout inLayout,
         int inBytes, ColorSyncDataLayout outLayout, int outBytes)
{
    unsigned char out[4] = {7, 7, 7, 7};
    bool ok = ColorSyncTransformConvert(t, 1, 1, out, kColorSync8BitInteger, outLayout, (size_t)outBytes, in,
                                        kColorSync8BitInteger, inLayout, (size_t)inBytes, NULL);
    printf("%s %d:", label, ok);
    for (int i = 0; i < inBytes; i++)
        printf(" %d", in[i]);
    printf(" ->");
    for (int i = 0; i < outBytes; i++)
        printf(" %d", out[i]);
    printf("\n");
}

static void
put32(unsigned char *p, unsigned v)
{
    p[0] = (unsigned char)(v >> 24), p[1] = (unsigned char)(v >> 16), p[2] = (unsigned char)(v >> 8), p[3] = (unsigned char)v;
}

/* A small gray ICC profile: a 'desc' tag, a white point and a gamma 2.2 'curv'. */
static CFDataRef
gray_profile_bytes(void)
{
    static unsigned char b[512];
    memset(b, 0, sizeof b);
    put32(b + 8, 0x02100000);
    memcpy(b + 12, "mntrGRAYXYZ ", 12);
    memcpy(b + 36, "acspAPPL", 8);
    put32(b + 68, 63190), put32(b + 72, 65536), put32(b + 76, 54061);
    put32(b + 128, 3);
    unsigned off = 132 + 36;
    const char *text = "Test Gray";
    put32(b + 132, 'desc'), put32(b + 136, off), put32(b + 140, 12 + 10 + 8 + 3 + 67);
    memcpy(b + off, "desc", 4), put32(b + off + 8, 10), memcpy(b + off + 12, text, 9);
    off += 12 + 10 + 8 + 3 + 67;
    put32(b + 144, 'wtpt'), put32(b + 148, off), put32(b + 152, 20);
    memcpy(b + off, "XYZ ", 4), put32(b + off + 8, 63190), put32(b + off + 12, 65536), put32(b + off + 16, 54061);
    off += 20;
    put32(b + 156, 'kTRC'), put32(b + 160, off), put32(b + 164, 14);
    memcpy(b + off, "curv", 4), put32(b + off + 8, 1), b[off + 12] = 2, b[off + 13] = 0x33;
    off += 16;
    put32(b, off);
    return CFDataCreate(NULL, b, off);
}

int
main(void)
{
    Dl_info info;
    dladdr((void *)ColorSyncTransformConvert, &info);
    printf("ColorSync: %s\n", info.dli_fname);

    CFStringRef names[] = {kColorSyncSRGBProfile, kColorSyncDisplayP3Profile, kColorSyncDCIP3Profile,
                           kColorSyncAdobeRGB1998Profile, kColorSyncITUR709Profile, kColorSyncITUR2020Profile,
                           kColorSyncACESCGLinearProfile, kColorSyncROMMRGBProfile, kColorSyncGenericRGBProfile,
                           kColorSyncGenericGrayProfile, kColorSyncGenericGrayGamma22Profile,
                           kColorSyncGenericLabProfile, kColorSyncGenericXYZProfile};
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        ColorSyncProfileRef p = ColorSyncProfileCreateWithName(names[i]);
        CFStringRef d = ColorSyncProfileCopyDescriptionString(p);
        print_string("name", names[i]);
        print_string("  description", d);
        CFDataRef h = ColorSyncProfileCopyHeader(p);
        const unsigned char *hb = CFDataGetBytePtr(h);
        printf("  class %.4s space %.4s pcs %.4s matrix %d wide %d tags rXYZ %d desc %d\n", hb + 12, hb + 16, hb + 20,
               ColorSyncProfileIsMatrixBased(p), ColorSyncProfileIsWideGamut(p),
               ColorSyncProfileContainsTag(p, CFSTR("rXYZ")), ColorSyncProfileContainsTag(p, CFSTR("desc")));
        CFRelease(h);
        if (d)
            CFRelease(d);
        CFRelease(p);
    }
    printf("unknown name: %p\n", (void *)ColorSyncProfileCreateWithName(CFSTR("com.apple.ColorSync.Nope")));

    ColorSyncTransformRef t = make_named(kColorSyncSRGBProfile, kColorSyncGenericLabProfile);
    convert_floats("sRGB->Lab", t, 3, 3);
    CFRelease(t);
    t = make_named(kColorSyncSRGBProfile, kColorSyncGenericGrayGamma22Profile);
    convert_floats("sRGB->Gray2.2", t, 3, 1);
    CFRelease(t);
    t = make_named(kColorSyncSRGBProfile, kColorSyncDisplayP3Profile);
    convert_floats("sRGB->P3", t, 3, 3);
    CFRelease(t);
    t = make_named(kColorSyncSRGBProfile, kColorSyncGenericXYZProfile);
    convert_floats("sRGB->XYZ", t, 3, 3);
    CFRelease(t);
    t = make_named(kColorSyncDisplayP3Profile, kColorSyncSRGBProfile);
    convert_floats("P3->sRGB", t, 3, 3);
    CFRelease(t);
    t = make_named(kColorSyncGenericLabProfile, kColorSyncSRGBProfile);
    convert_list("Lab->sRGB", t, 3, 3, kLabColors);
    CFRelease(t);
    t = make_named(kColorSyncITUR2020Profile, kColorSyncSRGBProfile);
    convert_floats("2020->sRGB", t, 3, 3);
    CFRelease(t);

    t = make_named(kColorSyncSRGBProfile, kColorSyncDisplayP3Profile);
    ColorSyncTransformRef id = make_named(kColorSyncSRGBProfile, kColorSyncSRGBProfile);
    unsigned char a[] = {64, 32, 16, 128}, b[] = {10, 200, 30, 128}, d[] = {128, 64, 32, 128}, z[] = {100, 100, 100, 0},
                  red[] = {255, 0, 0, 255};
    convert8("id premultiplied", id, a, kColorSyncAlphaPremultipliedLast, 4, kColorSyncAlphaPremultipliedLast, 4);
    convert8("id premultiplied", id, b, kColorSyncAlphaPremultipliedLast, 4, kColorSyncAlphaPremultipliedLast, 4);
    convert8("id premultiplied", id, z, kColorSyncAlphaPremultipliedLast, 4, kColorSyncAlphaPremultipliedLast, 4);
    convert8("p3 premultiplied", t, red, kColorSyncAlphaPremultipliedLast, 4, kColorSyncAlphaPremultipliedLast, 4);
    convert8("p3 premultiplied", t, a, kColorSyncAlphaPremultipliedLast, 4, kColorSyncAlphaPremultipliedLast, 4);
    convert8("p3 premultiplied", t, b, kColorSyncAlphaPremultipliedLast, 4, kColorSyncAlphaPremultipliedLast, 4);
    convert8("p3 premultiplied", t, d, kColorSyncAlphaPremultipliedLast, 4, kColorSyncAlphaPremultipliedLast, 4);
    convert8("p3 last", t, d, kColorSyncAlphaLast, 4, kColorSyncAlphaLast, 4);
    convert8("p3 none", t, d, kColorSyncAlphaNone, 3, kColorSyncAlphaNone, 3);
    convert8("p3 premultiplied->last", t, d, kColorSyncAlphaPremultipliedLast, 4, kColorSyncAlphaLast, 4);
    convert8("p3 last->premultiplied", t, d, kColorSyncAlphaLast, 4, kColorSyncAlphaPremultipliedLast, 4);
    convert8("p3 skip last", t, d, kColorSyncAlphaNoneSkipLast, 4, kColorSyncAlphaNoneSkipLast, 4);
    convert8("p3 first", t, d, kColorSyncAlphaFirst, 4, kColorSyncAlphaFirst, 4);
    convert8("p3 premultiplied first", t, d, kColorSyncAlphaPremultipliedFirst, 4, kColorSyncAlphaPremultipliedFirst, 4);
    convert8("p3 first 32little", t, d, kColorSyncAlphaFirst | kColorSyncByteOrder32Little, 4,
             kColorSyncAlphaFirst | kColorSyncByteOrder32Little, 4);
    convert8("p3 skip first 32little", t, d, kColorSyncAlphaNoneSkipFirst | kColorSyncByteOrder32Little, 4,
             kColorSyncAlphaNoneSkipFirst | kColorSyncByteOrder32Little, 4);
    convert8("p3 last->none", t, d, kColorSyncAlphaLast, 4, kColorSyncAlphaNone, 3);
    convert8("p3 none->last", t, d, kColorSyncAlphaNone, 3, kColorSyncAlphaLast, 4);
    CFRelease(id);

    /* a 2x2 image with row padding */
    unsigned char img[2][8] = {{255, 0, 0, 40, 160, 90, 9, 9}, {0, 0, 255, 128, 128, 128, 9, 9}}, outimg[2][8];
    memset(outimg, 7, sizeof outimg);
    bool ok = ColorSyncTransformConvert(t, 2, 2, outimg, kColorSync8BitInteger, kColorSyncAlphaNone, 8, img,
                                        kColorSync8BitInteger, kColorSyncAlphaNone, 8, NULL);
    printf("2x2 %d:", ok);
    for (int r = 0; r < 2; r++)
        for (int c = 0; c < 8; c++)
            printf(" %d", outimg[r][c]);
    printf("\n");
    CFRelease(t);

    /* a profile from ICC bytes */
    CFDataRef bytes = gray_profile_bytes();
    CFErrorRef error = NULL;
    ColorSyncProfileRef gray = ColorSyncProfileCreate(bytes, &error);
    printf("created %d error %d\n", gray != NULL, error != NULL);
    print_string("description", ColorSyncProfileCopyDescriptionString(gray));
    CFDataRef copy = ColorSyncProfileCopyData(gray, NULL);
    printf("data equal %d length %ld\n", CFEqual(copy, bytes), (long)CFDataGetLength(copy));
    CFDataRef header = ColorSyncProfileCopyHeader(gray);
    printf("header %ld:", (long)CFDataGetLength(header));
    for (int i = 0; i < 84; i++)
        printf("%s%02x", i % 4 ? "" : " ", CFDataGetBytePtr(header)[i]);
    printf("\n");
    ColorSyncMD5 md5 = ColorSyncProfileGetMD5(gray);
    printf("md5");
    for (int i = 0; i < 16; i++)
        printf(" %02x", md5.digest[i]);
    printf("\n");
    CFArrayRef sigs = ColorSyncProfileCopyTagSignatures(gray);
    printf("tags %ld:", (long)CFArrayGetCount(sigs));
    for (CFIndex i = 0; i < CFArrayGetCount(sigs); i++) {
        char s[8];
        CFStringGetCString(CFArrayGetValueAtIndex(sigs, i), s, sizeof s, kCFStringEncodingASCII);
        printf(" '%s'", s);
    }
    printf("\n");
    CFDataRef trc = ColorSyncProfileCopyTag(gray, CFSTR("kTRC"));
    printf("kTRC %ld bytes, gamma byte %d\n", (long)CFDataGetLength(trc), CFDataGetBytePtr(trc)[12]);
    printf("estimated gamma %.2f\n", ColorSyncProfileEstimateGamma(gray, NULL));
    ColorSyncTransformRef g = make_named(kColorSyncSRGBProfile, kColorSyncSRGBProfile);
    CFRelease(g);
    ColorSyncProfileRef srgb = ColorSyncProfileCreateWithName(kColorSyncSRGBProfile);
    g = make(srgb, gray);
    convert_list("sRGB->test gray", g, 3, 1, kLabColors);
    CFRelease(g);

    ColorSyncMutableProfileRef m = ColorSyncProfileCreateMutableCopy(gray);
    unsigned char tag[] = {'t', 'e', 'x', 't', 0, 0, 0, 0, 'h', 'i', 0, 0};
    CFDataRef tagdata = CFDataCreate(NULL, tag, sizeof tag);
    ColorSyncProfileSetTag(m, CFSTR("cprt"), tagdata);
    CFDataRef back = ColorSyncProfileCopyTag(m, CFSTR("cprt"));
    printf("set tag: contains %d equal %d count %ld\n", ColorSyncProfileContainsTag(m, CFSTR("cprt")),
           back && CFEqual(back, tagdata), (long)CFArrayGetCount(ColorSyncProfileCopyTagSignatures(m)));
    ColorSyncProfileRemoveTag(m, CFSTR("cprt"));
    printf("removed tag: contains %d count %ld\n", ColorSyncProfileContainsTag(m, CFSTR("cprt")),
           (long)CFArrayGetCount(ColorSyncProfileCopyTagSignatures(m)));
    print_string("mutable description", ColorSyncProfileCopyDescriptionString(m));
    printf("garbage profile: %p\n", (void *)ColorSyncProfileCreate(CFDataCreate(NULL, (const UInt8 *)"nope", 4), NULL));
    printf("type ids distinct %d\n", ColorSyncProfileGetTypeID() != ColorSyncTransformGetTypeID());
    return 0;
}
