/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ColorSync profiles: a CF type holding an ICC profile's bytes, which every call reads
 * (header, tag table, tags) and mutable profiles rewrite. The named profiles Apple's
 * ColorSync knows (sRGB, Display P3, the generic RGB, gray, Lab and XYZ ones, ...) are
 * written here as ICC v4 profiles with the colorants, curves and white points Apple's
 * have, so they convert as Apple's do.
 */
#include "ColorSyncInternal.h"
#include <CommonCrypto/CommonDigest.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>

/* --- big-endian fields --- */

uint32_t
cs_be32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static void
put_be32(uint8_t *p, uint32_t v)
{
    p[0] = v >> 24, p[1] = v >> 16, p[2] = v >> 8, p[3] = v;
}

static void
append32(CFMutableDataRef d, uint32_t v)
{
    uint8_t b[4];
    put_be32(b, v);
    CFDataAppendBytes(d, b, 4);
}

static void
append16(CFMutableDataRef d, uint16_t v)
{
    uint8_t b[2] = {(uint8_t)(v >> 8), (uint8_t)v};
    CFDataAppendBytes(d, b, 2);
}

static void
pad4(CFMutableDataRef d)
{
    static const uint8_t zero[4];
    CFIndex n = CFDataGetLength(d);
    if (n % 4)
        CFDataAppendBytes(d, zero, 4 - n % 4);
}

static uint32_t
sig_from_string(CFStringRef s)
{
    char b[8] = "    ";
    if (!s || !CFStringGetCString(s, b, sizeof b, kCFStringEncodingMacRoman))
        return 0;
    for (size_t i = strlen(b); i < 4; i++)
        b[i] = ' ';
    return (uint32_t)(uint8_t)b[0] << 24 | (uint32_t)(uint8_t)b[1] << 16 | (uint32_t)(uint8_t)b[2] << 8 | (uint8_t)b[3];
}

CFStringRef
cs_string_from_sig(uint32_t sig)
{
    char b[5] = {(char)(sig >> 24), (char)(sig >> 16), (char)(sig >> 8), (char)sig, 0};
    return CFStringCreateWithCString(NULL, b, kCFStringEncodingMacRoman);
}

/* --- the type --- */

struct ColorSyncProfile {
    CFRuntimeBase base;
    CFMutableDataRef data; /* the ICC profile */
    CFURLRef url;
    bool is_mutable;
};

static CFTypeID profile_type;

static void
profile_finalize(CFTypeRef cf)
{
    struct ColorSyncProfile *p = (struct ColorSyncProfile *)cf;
    if (p->data)
        CFRelease(p->data);
    if (p->url)
        CFRelease(p->url);
}

static Boolean
profile_equal(CFTypeRef a, CFTypeRef b)
{
    return CFEqual(((struct ColorSyncProfile *)a)->data, ((struct ColorSyncProfile *)b)->data);
}

static CFHashCode
profile_hash(CFTypeRef cf)
{
    return CFHash(((struct ColorSyncProfile *)cf)->data);
}

static CFStringRef
profile_description(CFTypeRef cf)
{
    CFStringRef desc = ColorSyncProfileCopyDescriptionString((ColorSyncProfileRef)cf);
    CFStringRef s = CFStringCreateWithFormat(NULL, NULL, CFSTR("<ColorSyncProfile %p [%@]>"), cf,
                                             desc ? desc : CFSTR("no description"));
    if (desc)
        CFRelease(desc);
    return s;
}

static const CFRuntimeClass profile_class = {
    0, "ColorSyncProfile", NULL, NULL, profile_finalize, profile_equal, profile_hash, NULL, profile_description,
    NULL, NULL, 0,
};

CFTypeID
ColorSyncProfileGetTypeID(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ profile_type = _CFRuntimeRegisterClass(&profile_class); });
    return profile_type;
}

static struct ColorSyncProfile *
profile_alloc(CFDataRef bytes, bool is_mutable)
{
    struct ColorSyncProfile *p = (struct ColorSyncProfile *)_CFRuntimeCreateInstance(
        NULL, ColorSyncProfileGetTypeID(), sizeof(*p) - sizeof(CFRuntimeBase), NULL);
    if (!p)
        return NULL;
    p->data = CFDataCreateMutableCopy(NULL, 0, bytes);
    p->is_mutable = is_mutable;
    return p;
}

const uint8_t *
cs_profile_bytes(ColorSyncProfileRef prof, size_t *len)
{
    *len = (size_t)CFDataGetLength(prof->data);
    return CFDataGetBytePtr(prof->data);
}

uint32_t
cs_profile_space(ColorSyncProfileRef prof)
{
    size_t n;
    const uint8_t *b = cs_profile_bytes(prof, &n);
    return n >= 128 ? cs_be32(b + 16) : 0;
}

uint32_t
cs_profile_pcs(ColorSyncProfileRef prof)
{
    size_t n;
    const uint8_t *b = cs_profile_bytes(prof, &n);
    return n >= 128 ? cs_be32(b + 20) : 0;
}

/* --- tags --- */

typedef struct {
    uint32_t sig;
    CFDataRef data;
} tag_entry;

/* The tag table: entries whose data lies inside the profile, in table order. */
static CFIndex
read_tags(ColorSyncProfileRef prof, tag_entry **out)
{
    size_t n;
    const uint8_t *b = cs_profile_bytes(prof, &n);
    *out = NULL;
    if (n < 132)
        return 0;
    uint32_t count = cs_be32(b + 128);
    if (count > (n - 132) / 12)
        return 0;
    tag_entry *t = calloc(count ? count : 1, sizeof *t);
    CFIndex k = 0;
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *e = b + 132 + 12 * i;
        uint32_t off = cs_be32(e + 4), len = cs_be32(e + 8);
        if (off > n || len > n - off)
            continue;
        t[k].sig = cs_be32(e);
        t[k].data = CFDataCreate(NULL, b + off, len);
        k++;
    }
    *out = t;
    return k;
}

static void
free_tags(tag_entry *t, CFIndex n)
{
    for (CFIndex i = 0; i < n; i++)
        CFRelease(t[i].data);
    free(t);
}

static const uint8_t *
find_tag(ColorSyncProfileRef prof, uint32_t sig, uint32_t *len)
{
    size_t n;
    const uint8_t *b = cs_profile_bytes(prof, &n);
    if (n < 132)
        return NULL;
    uint32_t count = cs_be32(b + 128);
    for (uint32_t i = 0; i < count && 132 + 12 * (size_t)(i + 1) <= n; i++) {
        const uint8_t *e = b + 132 + 12 * i;
        uint32_t off = cs_be32(e + 4), l = cs_be32(e + 8);
        if (cs_be32(e) == sig && off <= n && l <= n - off) {
            *len = l;
            return b + off;
        }
    }
    return NULL;
}

/* Lays the profile out again from `header` (128 bytes) and the tags: the table, then
   each tag's data 4-byte aligned, tags with the same bytes sharing them. */
static CFMutableDataRef
build_profile(const uint8_t *header, const tag_entry *tags, CFIndex count)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    CFDataAppendBytes(d, header, 128);
    append32(d, (uint32_t)count);
    CFDataIncreaseLength(d, 12 * count);
    uint32_t *offsets = calloc(count ? count : 1, sizeof *offsets);
    for (CFIndex i = 0; i < count; i++) {
        CFIndex same = -1;
        for (CFIndex j = 0; j < i && same < 0; j++)
            if (CFEqual(tags[j].data, tags[i].data))
                same = j;
        if (same >= 0) {
            offsets[i] = offsets[same];
        } else {
            pad4(d);
            offsets[i] = (uint32_t)CFDataGetLength(d);
            CFDataAppendBytes(d, CFDataGetBytePtr(tags[i].data), CFDataGetLength(tags[i].data));
        }
    }
    pad4(d);
    uint8_t *b = CFDataGetMutableBytePtr(d);
    for (CFIndex i = 0; i < count; i++) {
        uint8_t *e = b + 132 + 12 * i;
        put_be32(e, tags[i].sig);
        put_be32(e + 4, offsets[i]);
        put_be32(e + 8, (uint32_t)CFDataGetLength(tags[i].data));
    }
    put_be32(b, (uint32_t)CFDataGetLength(d));
    free(offsets);
    return d;
}

/* The ICC profile ID: MD5 of the profile with its flags, intent and ID zeroed. */
static void
profile_id(const uint8_t *b, size_t n, uint8_t digest[16])
{
    uint8_t *copy = malloc(n);
    memcpy(copy, b, n);
    if (n >= 128) {
        memset(copy + 44, 0, 4);
        memset(copy + 64, 0, 4);
        memset(copy + 84, 0, 16);
    }
    CC_MD5(copy, (CC_LONG)n, digest);
    free(copy);
}

/* --- the named profiles --- */

typedef struct {
    int16_t type; /* ICC parametric curve type, or -1 for none */
    int32_t params[7];
} para_curve;

/* D50, as ICC encodes it. */
static const int32_t kD50[3] = {63190, 65536, 54061};

enum { NAMED_RGB, NAMED_GRAY, NAMED_LAB, NAMED_XYZ };

typedef struct {
    CFStringRef const *name;
    const char *description;
    int kind;
    int32_t white[3];   /* the media white point, D50 for v4 */
    int32_t rgb[3][3];  /* rXYZ, gXYZ, bXYZ, adapted to D50 */
    para_curve curve;
    double source_white[2]; /* chromaticity of the encoding's white, for chad */
} named_profile;

#define SRGB_CURVE {3, {157286, 62119, 3417, 5072, 2651}}
#define D65 {0.3127, 0.3290}

static const named_profile named_profiles[] = {
    {&kColorSyncSRGBProfile, "sRGB IEC61966-2.1", NAMED_RGB, {63190, 65536, 54061},
     {{28578, 14581, 912}, {25241, 46981, 6362}, {9376, 3972, 46799}}, SRGB_CURVE, D65},
    {&kColorSyncDisplayP3Profile, "Display P3", NAMED_RGB, {63189, 65536, 54060},
     {{33759, 15807, -69}, {19135, 45367, 2745}, {10296, 4363, 51385}}, SRGB_CURVE, D65},
    {&kColorSyncDCIP3Profile, "SMPTE RP 431-2-2007 DCI (P3)", NAMED_RGB, {63189, 65536, 54060},
     {{31861, 14856, -53}, {21224, 46552, 2833}, {10105, 4128, 51280}}, {0, {170394}}, {0.314, 0.351}},
    {&kColorSyncAdobeRGB1998Profile, "Adobe RGB (1998)", NAMED_RGB, {63190, 65536, 54061},
     {{39960, 20389, 1276}, {13453, 41004, 3989}, {9777, 4143, 48796}}, {0, {563 * 256}}, D65},
    {&kColorSyncITUR709Profile, "Rec. ITU-R BT.709-5", NAMED_RGB, {63189, 65536, 54060},
     {{28578, 14581, 912}, {25241, 46981, 6362}, {9376, 3972, 46799}},
     {3, {145636, 59632, 5904, 14564, 5308}}, D65},
    {&kColorSyncITUR2020Profile, "Rec. ITU-R BT.2020-1", NAMED_RGB, {63190, 65536, 54061},
     {{44137, 18287, -127}, {10857, 44259, 1965}, {8195, 2989, 52222}},
     {3, {145636, 59616, 5920, 14564, 5308}}, D65},
    {&kColorSyncACESCGLinearProfile, "ACES CG Linear (Academy Color Encoding System AP1)", NAMED_RGB,
     {63189, 65536, 54060}, {{45212, 18646, -396}, {9815, 44020, 656}, {8163, 2870, 53801}}, {0, {65536}},
     {0.32168, 0.33767}},
    {&kColorSyncROMMRGBProfile, "ROMM RGB: ISO 22028-2:2013", NAMED_RGB, {63189, 65536, 54060},
     {{52276, 18877, 0}, {8860, 46654, 0}, {2055, 6, 54080}}, {3, {117965, 65536, 0, 4096, 128}},
     {0.3457, 0.3585}},
    {&kColorSyncGenericRGBProfile, "Generic RGB Profile", NAMED_RGB, {63190, 65536, 54061},
     {{29773, 15854, 976}, {23157, 44147, 5940}, {10266, 5535, 47158}}, {0, {461 * 256}}, D65},
    {&kColorSyncGenericGrayProfile, "Generic Gray Profile", NAMED_GRAY, {63190, 65536, 54061}, {{0}},
     {0, {461 * 256}}, D65},
    {&kColorSyncGenericGrayGamma22Profile, "Generic Gray Gamma 2.2 Profile", NAMED_GRAY,
     {63190, 65536, 54061}, {{0}}, SRGB_CURVE, D65},
    {&kColorSyncGenericLabProfile, "Generic L*a*b* Profile", NAMED_LAB, {63189, 65536, 54060}, {{0}},
     {-1, {0}}, {0.3457, 0.3585}},
    {&kColorSyncGenericXYZProfile, "Generic XYZ Profile", NAMED_XYZ, {63189, 65536, 54060}, {{0}},
     {-1, {0}}, {0.3457, 0.3585}},
};

static CFDataRef
mluc_tag(const char *text)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    size_t n = strlen(text);
    append32(d, 'mluc');
    append32(d, 0);
    append32(d, 1);
    append32(d, 12);
    append16(d, 'e' << 8 | 'n');
    append16(d, 'U' << 8 | 'S');
    append32(d, (uint32_t)(2 * n));
    append32(d, 28);
    for (size_t i = 0; i < n; i++)
        append16(d, (uint8_t)text[i]);
    pad4(d);
    return d;
}

static CFDataRef
xyz_tag(const int32_t v[3])
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    append32(d, 'XYZ ');
    append32(d, 0);
    for (int i = 0; i < 3; i++)
        append32(d, (uint32_t)v[i]);
    return d;
}

static CFDataRef
para_tag(const para_curve *c)
{
    static const int counts[] = {1, 3, 4, 5, 7};
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    append32(d, 'para');
    append32(d, 0);
    append16(d, (uint16_t)c->type);
    append16(d, 0);
    for (int i = 0; i < counts[c->type]; i++)
        append32(d, (uint32_t)c->params[i]);
    return d;
}

/* An identity lutAtoBType / lutBtoAType ('mAB ' / 'mBA '): three linear B curves,
   which is all a PCS-to-PCS profile (Lab, XYZ) needs. */
static CFDataRef
identity_lut_tag(uint32_t type)
{
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    append32(d, type);
    append32(d, 0);
    uint8_t channels[4] = {3, 3, 0, 0};
    CFDataAppendBytes(d, channels, 4);
    append32(d, 32); /* the B curves */
    for (int i = 0; i < 4; i++)
        append32(d, 0); /* no matrix, M curves, CLUT or A curves */
    para_curve linear = {0, {65536}};
    for (int i = 0; i < 3; i++) {
        CFDataRef c = para_tag(&linear);
        CFDataAppendBytes(d, CFDataGetBytePtr(c), CFDataGetLength(c));
        CFRelease(c);
    }
    return d;
}

static int32_t
s15(double v)
{
    return (int32_t)lround(v * 65536.0);
}

/* Bradford adaptation from the white with chromaticity xy to D50. */
static void
bradford_to_d50(const double xy[2], double out[9])
{
    static const double B[9] = {0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296};
    static const double Bi[9] = {0.9869929, -0.1470543, 0.1599627, 0.4323053, 0.5183603, 0.0492912,
                                 -0.0085287, 0.0400428, 0.9684867};
    double src[3] = {xy[0] / xy[1], 1, (1 - xy[0] - xy[1]) / xy[1]};
    double dst[3] = {0.9642, 1, 0.8249};
    double s[3], t[3], m[9];
    for (int i = 0; i < 3; i++) {
        s[i] = B[3 * i] * src[0] + B[3 * i + 1] * src[1] + B[3 * i + 2] * src[2];
        t[i] = B[3 * i] * dst[0] + B[3 * i + 1] * dst[1] + B[3 * i + 2] * dst[2];
    }
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            m[3 * i + j] = B[3 * i + j] * t[i] / s[i];
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            out[3 * i + j] = Bi[3 * i] * m[j] + Bi[3 * i + 1] * m[3 + j] + Bi[3 * i + 2] * m[6 + j];
}

static CFDataRef
chad_tag(const double xy[2])
{
    double m[9];
    bradford_to_d50(xy, m);
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    append32(d, 'sf32');
    append32(d, 0);
    for (int i = 0; i < 9; i++)
        append32(d, (uint32_t)s15(m[i]));
    return d;
}

static void
make_header(uint8_t h[128], uint32_t cls, uint32_t space, uint32_t pcs)
{
    memset(h, 0, 128);
    put_be32(h + 8, 0x04400000); /* ICC 4.4 */
    put_be32(h + 12, cls);
    put_be32(h + 16, space);
    put_be32(h + 20, pcs);
    static const uint16_t date[6] = {2026, 1, 1, 0, 0, 0};
    for (int i = 0; i < 6; i++)
        h[24 + 2 * i] = date[i] >> 8, h[25 + 2 * i] = (uint8_t)date[i];
    put_be32(h + 36, 'acsp');
    put_be32(h + 40, 'APPL');
    for (int i = 0; i < 3; i++)
        put_be32(h + 68 + 4 * i, (uint32_t)kD50[i]);
    put_be32(h + 80, 'fnch');
}

static void
set_profile_id(CFMutableDataRef d)
{
    uint8_t digest[16];
    profile_id(CFDataGetBytePtr(d), (size_t)CFDataGetLength(d), digest);
    memcpy(CFDataGetMutableBytePtr(d) + 84, digest, 16);
}

static CFDataRef
named_profile_data(const named_profile *np)
{
    uint8_t h[128];
    tag_entry tags[12];
    CFIndex n = 0;
    tags[n++] = (tag_entry){'desc', mluc_tag(np->description)};
    tags[n++] = (tag_entry){'cprt', mluc_tag("No copyright, use freely")};
    tags[n++] = (tag_entry){'wtpt', xyz_tag(np->white)};
    switch (np->kind) {
    case NAMED_RGB:
        make_header(h, 'mntr', 'RGB ', 'XYZ ');
        tags[n++] = (tag_entry){'rXYZ', xyz_tag(np->rgb[0])};
        tags[n++] = (tag_entry){'gXYZ', xyz_tag(np->rgb[1])};
        tags[n++] = (tag_entry){'bXYZ', xyz_tag(np->rgb[2])};
        tags[n++] = (tag_entry){'rTRC', para_tag(&np->curve)};
        tags[n++] = (tag_entry){'gTRC', para_tag(&np->curve)};
        tags[n++] = (tag_entry){'bTRC', para_tag(&np->curve)};
        tags[n++] = (tag_entry){'chad', chad_tag(np->source_white)};
        break;
    case NAMED_GRAY:
        make_header(h, 'mntr', 'GRAY', 'XYZ ');
        tags[n++] = (tag_entry){'kTRC', para_tag(&np->curve)};
        break;
    case NAMED_LAB:
    case NAMED_XYZ: {
        uint32_t space = np->kind == NAMED_LAB ? 'Lab ' : 'XYZ ';
        make_header(h, 'spac', space, space);
        tags[n++] = (tag_entry){'A2B0', identity_lut_tag('mAB ')};
        tags[n++] = (tag_entry){'B2A0', identity_lut_tag('mBA ')};
        break;
    }
    }
    CFMutableDataRef d = build_profile(h, tags, n);
    for (CFIndex i = 0; i < n; i++)
        CFRelease(tags[i].data);
    set_profile_id(d);
    return d;
}

/* --- creating profiles --- */

static bool
looks_like_icc(CFDataRef data)
{
    CFIndex n = CFDataGetLength(data);
    const uint8_t *b = CFDataGetBytePtr(data);
    return n >= 132 && cs_be32(b + 36) == 'acsp' && cs_be32(b) <= (uint32_t)n && cs_be32(b) >= 132;
}

static void
set_error(CFErrorRef *error, CFIndex code)
{
    if (error)
        *error = CFErrorCreate(NULL, kCFErrorDomainOSStatus, code, NULL);
}

ColorSyncProfileRef
ColorSyncProfileCreate(CFDataRef data, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    if (!data || !looks_like_icc(data)) {
        set_error(error, -171 /* cmProfileError */);
        return NULL;
    }
    CFDataRef exact = CFDataCreate(NULL, CFDataGetBytePtr(data), cs_be32(CFDataGetBytePtr(data)));
    struct ColorSyncProfile *p = profile_alloc(exact, false);
    CFRelease(exact);
    return p;
}

ColorSyncProfileRef
ColorSyncProfileCreateWithName(CFStringRef name)
{
    if (!name)
        return NULL;
    for (size_t i = 0; i < sizeof named_profiles / sizeof *named_profiles; i++)
        if (CFEqual(name, *named_profiles[i].name)) {
            CFDataRef d = named_profile_data(&named_profiles[i]);
            struct ColorSyncProfile *p = profile_alloc(d, false);
            CFRelease(d);
            return p;
        }
    return NULL;
}

static ColorSyncProfileRef
create_with_url(CFURLRef url, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    char path[PATH_MAX];
    if (!url || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path)) {
        set_error(error, -43 /* fnfErr */);
        return NULL;
    }
    FILE *f = fopen(path, "rb");
    if (!f) {
        set_error(error, -43);
        return NULL;
    }
    CFMutableDataRef d = CFDataCreateMutable(NULL, 0);
    uint8_t buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0)
        CFDataAppendBytes(d, buf, (CFIndex)n);
    fclose(f);
    struct ColorSyncProfile *p = (struct ColorSyncProfile *)ColorSyncProfileCreate(d, error);
    CFRelease(d);
    if (p)
        p->url = CFRetain(url);
    return p;
}

ColorSyncProfileRef
ColorSyncProfileCreateWithURLAndOptions(CFURLRef url, CFDictionaryRef options, CFErrorRef *error)
{
    return create_with_url(url, error);
}

ColorSyncProfileRef
ColorSyncProfileCreateWithURL(CFURLRef url, CFErrorRef *error)
{
    return create_with_url(url, error);
}

ColorSyncProfileRef
ColorSyncProfileCreateWithDisplayID(uint32_t displayID)
{
    /* Finch's displays are sRGB until displays report their own colorimetry. */
    return ColorSyncProfileCreateWithName(kColorSyncSRGBProfile);
}

ColorSyncProfileRef
ColorSyncProfileCreateDeviceProfile(CFStringRef deviceClass, CFUUIDRef deviceID, CFTypeRef profileID)
{
    if (deviceClass && CFEqual(deviceClass, kColorSyncDisplayDeviceClass))
        return ColorSyncProfileCreateWithName(kColorSyncSRGBProfile);
    return NULL;
}

ColorSyncMutableProfileRef
ColorSyncProfileCreateMutable(void)
{
    uint8_t h[128];
    make_header(h, 'mntr', 'RGB ', 'XYZ ');
    CFMutableDataRef d = build_profile(h, NULL, 0);
    struct ColorSyncProfile *p = profile_alloc(d, true);
    CFRelease(d);
    return p;
}

ColorSyncMutableProfileRef
ColorSyncProfileCreateMutableCopy(ColorSyncProfileRef prof)
{
    if (!prof)
        return NULL;
    struct ColorSyncProfile *p = profile_alloc(prof->data, true);
    if (p && prof->url)
        p->url = CFRetain(prof->url);
    return p;
}

ColorSyncProfileRef
ColorSyncProfileCreateLink(CFArrayRef profileInfo, CFDictionaryRef options)
{
    /* Device links (one profile holding a whole sequence's conversion) need ICC LUT
       writing, which Finch's ColorSync doesn't do yet. */
    return NULL;
}

/* --- reading profiles --- */

bool
ColorSyncProfileVerify(ColorSyncProfileRef prof, CFErrorRef *errors, CFErrorRef *warnings)
{
    if (errors)
        *errors = NULL;
    if (warnings)
        *warnings = NULL;
    if (!prof || !looks_like_icc(prof->data)) {
        set_error(errors, -171);
        return false;
    }
    return true;
}

ColorSyncMD5
ColorSyncProfileGetMD5(ColorSyncProfileRef prof)
{
    ColorSyncMD5 md5;
    memset(&md5, 0, sizeof md5);
    if (!prof)
        return md5;
    size_t n;
    const uint8_t *b = cs_profile_bytes(prof, &n);
    static const uint8_t zero[16];
    if (n >= 128 && memcmp(b + 84, zero, 16))
        memcpy(md5.digest, b + 84, 16);
    else
        profile_id(b, n, md5.digest);
    return md5;
}

CFDataRef
ColorSyncProfileCopyData(ColorSyncProfileRef prof, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    return prof ? CFDataCreateCopy(NULL, prof->data) : NULL;
}

CFDataRef
ColorSyncProfileGetData(ColorSyncProfileRef prof)
{
    return prof ? prof->data : NULL;
}

CFURLRef
ColorSyncProfileGetURL(ColorSyncProfileRef prof, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    return prof ? prof->url : NULL;
}

/* ColorSync hands headers out in the host's byte order, field by field. */
static void
swap_header(uint8_t h[128])
{
    for (int off = 0; off < 128;) {
        if (off == 24) { /* the date: six 16-bit fields */
            for (int i = 0; i < 6; i++) {
                uint8_t t = h[24 + 2 * i];
                h[24 + 2 * i] = h[25 + 2 * i], h[25 + 2 * i] = t;
            }
            off = 36;
        } else if (off == 84) { /* the profile ID and reserved bytes stay as they are */
            break;
        } else {
            uint32_t v = cs_be32(h + off);
            memcpy(h + off, &v, 4);
            off += 4;
        }
    }
}

CFDataRef
ColorSyncProfileCopyHeader(ColorSyncProfileRef prof)
{
    uint8_t h[128] = {0};
    size_t n;
    const uint8_t *b = cs_profile_bytes(prof, &n);
    memcpy(h, b, n < 128 ? n : 128);
    swap_header(h);
    return CFDataCreate(NULL, h, 128);
}

void
ColorSyncSwapProfileHeader(void *header)
{
    swap_header(header);
}

static void
rewrite(struct ColorSyncProfile *p, const uint8_t header[128], tag_entry *tags, CFIndex count)
{
    CFMutableDataRef d = build_profile(header, tags, count);
    CFRelease(p->data);
    p->data = d;
}

void
ColorSyncProfileSetHeader(ColorSyncMutableProfileRef prof, CFDataRef header)
{
    if (!prof || !header || CFDataGetLength(header) < 128)
        return;
    uint8_t h[128];
    memcpy(h, CFDataGetBytePtr(header), 128);
    /* back to big-endian: the swap is its own inverse */
    for (int off = 0; off < 84;) {
        if (off == 24) {
            for (int i = 0; i < 6; i++) {
                uint8_t t = h[24 + 2 * i];
                h[24 + 2 * i] = h[25 + 2 * i], h[25 + 2 * i] = t;
            }
            off = 36;
        } else {
            uint32_t v;
            memcpy(&v, h + off, 4);
            put_be32(h + off, v);
            off += 4;
        }
    }
    tag_entry *tags;
    CFIndex count = read_tags(prof, &tags);
    rewrite(prof, h, tags, count);
    free_tags(tags, count);
}

CFArrayRef
ColorSyncProfileCopyTagSignatures(ColorSyncProfileRef prof)
{
    if (!prof)
        return NULL;
    tag_entry *tags;
    CFIndex count = read_tags(prof, &tags);
    CFMutableArrayRef a = CFArrayCreateMutable(NULL, count, &kCFTypeArrayCallBacks);
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef s = cs_string_from_sig(tags[i].sig);
        CFArrayAppendValue(a, s);
        CFRelease(s);
    }
    free_tags(tags, count);
    return a;
}

CFIndex
ColorSyncProfileGetTagCount(ColorSyncProfileRef prof)
{
    tag_entry *tags;
    CFIndex count = prof ? read_tags(prof, &tags) : 0;
    if (prof)
        free_tags(tags, count);
    return count;
}

bool
ColorSyncProfileContainsTag(ColorSyncProfileRef prof, CFStringRef signature)
{
    uint32_t len;
    return prof && find_tag(prof, sig_from_string(signature), &len);
}

CFDataRef
ColorSyncProfileCopyTag(ColorSyncProfileRef prof, CFStringRef signature)
{
    uint32_t len;
    const uint8_t *t = prof ? find_tag(prof, sig_from_string(signature), &len) : NULL;
    return t ? CFDataCreate(NULL, t, len) : NULL;
}

void
ColorSyncProfileSetTag(ColorSyncMutableProfileRef prof, CFStringRef signature, CFDataRef data)
{
    if (!prof || !data)
        return;
    uint32_t sig = sig_from_string(signature);
    tag_entry *tags;
    CFIndex count = read_tags(prof, &tags);
    tags = realloc(tags, sizeof *tags * (size_t)(count + 1));
    CFIndex i;
    for (i = 0; i < count && tags[i].sig != sig; i++)
        ;
    if (i == count)
        count++;
    else
        CFRelease(tags[i].data);
    tags[i] = (tag_entry){sig, CFDataCreateCopy(NULL, data)};
    uint8_t h[128];
    memcpy(h, CFDataGetBytePtr(prof->data), 128);
    rewrite(prof, h, tags, count);
    free_tags(tags, count);
}

void
ColorSyncProfileRemoveTag(ColorSyncMutableProfileRef prof, CFStringRef signature)
{
    if (!prof)
        return;
    uint32_t sig = sig_from_string(signature);
    tag_entry *tags;
    CFIndex count = read_tags(prof, &tags), k = 0;
    for (CFIndex i = 0; i < count; i++) {
        if (tags[i].sig == sig)
            CFRelease(tags[i].data);
        else
            tags[k++] = tags[i];
    }
    uint8_t h[128];
    memcpy(h, CFDataGetBytePtr(prof->data), 128);
    rewrite(prof, h, tags, k);
    free_tags(tags, k);
}

/* --- descriptions --- */

/* A 'desc' (ICC v2), 'mluc' (v4, the language asked for if there, else English, else
   the first) or 'text' tag's string. */
static CFStringRef
tag_string(const uint8_t *t, uint32_t len, const char *lang, const char *region, bool ascii)
{
    if (len < 12)
        return NULL;
    switch (cs_be32(t)) {
    case 'desc': {
        uint32_t n = cs_be32(t + 8);
        if (n > len - 12)
            return NULL;
        while (n && t[12 + n - 1] == 0)
            n--;
        CFStringRef s = CFStringCreateWithBytes(NULL, t + 12, n, kCFStringEncodingMacRoman, false);
        if (!ascii && s) {
            /* the Unicode form follows, when there is one */
            uint32_t off = 12 + cs_be32(t + 8);
            if (off + 8 <= len) {
                uint32_t count = cs_be32(t + off + 4);
                if (count > 1 && off + 8 + 2 * count <= len) {
                    while (count && t[off + 8 + 2 * (count - 1)] == 0 && t[off + 9 + 2 * (count - 1)] == 0)
                        count--;
                    CFStringRef u = CFStringCreateWithBytes(NULL, t + off + 8, 2 * count, kCFStringEncodingUTF16BE, false);
                    if (u && CFStringGetLength(u)) {
                        CFRelease(s);
                        return u;
                    }
                    if (u)
                        CFRelease(u);
                }
            }
        }
        return s;
    }
    case 'text': {
        uint32_t n = len - 8;
        while (n && t[8 + n - 1] == 0)
            n--;
        return CFStringCreateWithBytes(NULL, t + 8, n, kCFStringEncodingMacRoman, false);
    }
    case 'mluc': {
        uint32_t count = cs_be32(t + 8), size = cs_be32(t + 12);
        if (size < 12 || count == 0 || 16 + (uint64_t)count * size > len)
            return NULL;
        uint32_t pick = 0;
        int best = -1;
        for (uint32_t i = 0; i < count; i++) {
            const uint8_t *r = t + 16 + i * size;
            int score = 0;
            if (lang && r[0] == lang[0] && r[1] == lang[1])
                score = (region && r[2] == region[0] && r[3] == region[1]) ? 4 : 3;
            else if (r[0] == 'e' && r[1] == 'n')
                score = (r[2] == 'U' && r[3] == 'S') ? 2 : 1;
            if (score > best)
                best = score, pick = i;
        }
        const uint8_t *r = t + 16 + pick * size;
        uint32_t n = cs_be32(r + 4), off = cs_be32(r + 8);
        if (off > len || n > len - off)
            return NULL;
        while (n >= 2 && t[off + n - 1] == 0 && t[off + n - 2] == 0)
            n -= 2;
        return CFStringCreateWithBytes(NULL, t + off, n, kCFStringEncodingUTF16BE, false);
    }
    }
    return NULL;
}

static CFStringRef
copy_description(ColorSyncProfileRef prof, const char *lang, const char *region, bool ascii)
{
    uint32_t len;
    const uint8_t *t = prof ? find_tag(prof, 'desc', &len) : NULL;
    return t ? tag_string(t, len, lang, region, ascii) : NULL;
}

CFStringRef
ColorSyncProfileCopyDescriptionString(ColorSyncProfileRef prof)
{
    return copy_description(prof, NULL, NULL, false);
}

CFStringRef
ColorSyncProfileCopyASCIIDescriptionString(ColorSyncProfileRef prof)
{
    return copy_description(prof, NULL, NULL, true);
}

CFStringRef
ColorSyncProfileCopyLocalizedDescriptionString(ColorSyncProfileRef prof, CFStringRef languageCode,
                                               CFStringRef regionCode)
{
    char lang[4] = "", region[4] = "";
    if (languageCode)
        CFStringGetCString(languageCode, lang, sizeof lang, kCFStringEncodingASCII);
    if (regionCode)
        CFStringGetCString(regionCode, region, sizeof region, kCFStringEncodingASCII);
    return copy_description(prof, lang[0] ? lang : NULL, region[0] ? region : NULL, false);
}

/* --- what a profile is --- */

bool
ColorSyncProfileIsMatrixBased(ColorSyncProfileRef prof)
{
    uint32_t len;
    uint32_t space = cs_profile_space(prof);
    if (space == 'GRAY')
        return find_tag(prof, 'kTRC', &len) != NULL;
    return space == 'RGB ' && find_tag(prof, 'rXYZ', &len) && find_tag(prof, 'rTRC', &len);
}

/* Wider than sRGB: the colorants' triangle (in xy) is a tenth larger than sRGB's. */
bool
ColorSyncProfileIsWideGamut(ColorSyncProfileRef prof)
{
    if (!prof || cs_profile_space(prof) != 'RGB ')
        return false;
    double xy[3][2];
    static const uint32_t sigs[3] = {'rXYZ', 'gXYZ', 'bXYZ'};
    for (int i = 0; i < 3; i++) {
        uint32_t len;
        const uint8_t *t = find_tag(prof, sigs[i], &len);
        if (!t || len < 20)
            return false;
        double X = (int32_t)cs_be32(t + 8) / 65536.0, Y = (int32_t)cs_be32(t + 12) / 65536.0,
               Z = (int32_t)cs_be32(t + 16) / 65536.0, sum = X + Y + Z;
        if (sum <= 0)
            return false;
        xy[i][0] = X / sum, xy[i][1] = Y / sum;
    }
    double area = fabs((xy[1][0] - xy[0][0]) * (xy[2][1] - xy[0][1]) - (xy[2][0] - xy[0][0]) * (xy[1][1] - xy[0][1])) / 2;
    return area > 0.1121 * 1.1; /* sRGB's, adapted to D50 */
}

static bool
transfer_is(ColorSyncProfileRef prof, bool (*test)(const skcms_TransferFunction *))
{
    cs_model m;
    if (!prof || !cs_model_init(&m, prof, false))
        return false;
    bool r = (m.kind == CS_MODEL_RGB || m.kind == CS_MODEL_GRAY) && m.curve[0].table_entries == 0 &&
             test(&m.curve[0].parametric);
    cs_model_free(&m);
    return r;
}

bool
ColorSyncProfileIsPQBased(ColorSyncProfileRef prof)
{
    return transfer_is(prof, skcms_TransferFunction_isPQish) || transfer_is(prof, skcms_TransferFunction_isPQ);
}

bool
ColorSyncProfileIsHLGBased(ColorSyncProfileRef prof)
{
    return transfer_is(prof, skcms_TransferFunction_isHLGish) || transfer_is(prof, skcms_TransferFunction_isHLG);
}

bool
ColorSyncProfileUsesSRGBGamma(ColorSyncProfileRef prof)
{
    return transfer_is(prof, skcms_TransferFunction_isSRGBish);
}

/* The gamma a pure power curve would need to pass through the profile's curve at 0.5. */
float
ColorSyncProfileEstimateGamma(ColorSyncProfileRef prof, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    cs_model m;
    if (!prof || !cs_model_init(&m, prof, false))
        return 0;
    float g = 0;
    if (m.kind == CS_MODEL_RGB || m.kind == CS_MODEL_GRAY) {
        float y = cs_curve_eval(&m.curve[m.kind == CS_MODEL_RGB ? 1 : 0], 0.5f);
        if (y > 0 && y < 1)
            g = logf(y) / logf(0.5f);
    }
    cs_model_free(&m);
    return g;
}

float
ColorSyncProfileEstimateGammaWithDisplayID(const int32_t displayID, CFErrorRef *error)
{
    ColorSyncProfileRef p = ColorSyncProfileCreateWithDisplayID((uint32_t)displayID);
    float g = ColorSyncProfileEstimateGamma(p, error);
    if (p)
        CFRelease(p);
    return g;
}

bool
ColorSyncProfileGetDisplayTransferFormulaFromVCGT(ColorSyncProfileRef profile, float *redMin, float *redMax,
                                                  float *redGamma, float *greenMin, float *greenMax,
                                                  float *greenGamma, float *blueMin, float *blueMax,
                                                  float *blueGamma)
{
    return false; /* Finch's profiles carry no video card gamma */
}

CFDataRef
ColorSyncProfileCreateDisplayTransferTablesFromVCGT(ColorSyncProfileRef profile, size_t *nSamplesPerChannel)
{
    return NULL;
}

/* --- installed profiles --- */

static const char *
home_dir(void)
{
    const char *h = getenv("HOME");
    return h && *h ? h : "/var/root";
}

static CFDictionaryRef
profile_info(ColorSyncProfileRef p, CFURLRef url)
{
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    size_t n;
    const uint8_t *b = cs_profile_bytes(p, &n);
    CFStringRef cls = cs_string_from_sig(cs_be32(b + 12)), space = cs_string_from_sig(cs_be32(b + 16));
    CFDictionarySetValue(d, kColorSyncProfileClass, cls);
    CFDictionarySetValue(d, kColorSyncProfileColorSpace, space);
    CFRelease(cls);
    CFRelease(space);
    CFDataRef header = ColorSyncProfileCopyHeader(p);
    CFDictionarySetValue(d, kColorSyncProfileHeader, header);
    CFRelease(header);
    CFStringRef desc = ColorSyncProfileCopyDescriptionString(p);
    if (desc) {
        CFDictionarySetValue(d, kColorSyncProfileDescription, desc);
        CFRelease(desc);
    }
    ColorSyncMD5 md5 = ColorSyncProfileGetMD5(p);
    CFDataRef md5d = CFDataCreate(NULL, md5.digest, 16);
    CFDictionarySetValue(d, kColorSyncProfileMD5Digest, md5d);
    CFRelease(md5d);
    CFDictionarySetValue(d, kColorSyncProfileIsValid, kCFBooleanTrue);
    if (url)
        CFDictionarySetValue(d, kColorSyncProfileURL, url);
    return d;
}

void
ColorSyncIterateInstalledProfilesWithOptions(ColorSyncProfileIterateCallback callBack, uint32_t *seed,
                                             void *userInfo, CFDictionaryRef options, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    if (seed)
        *seed = 1;
    if (!callBack)
        return;
    char user[PATH_MAX];
    snprintf(user, sizeof user, "%s/Library/ColorSync/Profiles", home_dir());
    const char *dirs[] = {user, "/Library/ColorSync/Profiles", "/System/Library/ColorSync/Profiles"};
    for (size_t i = 0; i < sizeof dirs / sizeof *dirs; i++) {
        DIR *dir = opendir(dirs[i]);
        if (!dir)
            continue;
        struct dirent *e;
        while ((e = readdir(dir))) {
            if (e->d_name[0] == '.')
                continue;
            char path[PATH_MAX];
            snprintf(path, sizeof path, "%s/%s", dirs[i], e->d_name);
            CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
            ColorSyncProfileRef p = ColorSyncProfileCreateWithURL(url, NULL);
            bool go = true;
            if (p) {
                CFDictionaryRef info = profile_info(p, url);
                go = callBack(info, userInfo);
                CFRelease(info);
                CFRelease(p);
            }
            CFRelease(url);
            if (!go) {
                closedir(dir);
                return;
            }
        }
        closedir(dir);
    }
}

void
ColorSyncIterateInstalledProfiles(ColorSyncProfileIterateCallback callBack, uint32_t *seed, void *userInfo,
                                  CFErrorRef *error)
{
    ColorSyncIterateInstalledProfilesWithOptions(callBack, seed, userInfo, NULL, error);
}

bool
ColorSyncProfileInstall(ColorSyncProfileRef profile, CFStringRef domain, CFStringRef subpath, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    if (!profile)
        return false;
    char dir[PATH_MAX], sub[PATH_MAX] = "";
    if (domain && CFEqual(domain, kColorSyncProfileComputerDomain))
        snprintf(dir, sizeof dir, "/Library/ColorSync/Profiles");
    else
        snprintf(dir, sizeof dir, "%s/Library/ColorSync/Profiles", home_dir());
    if (subpath)
        CFStringGetFileSystemRepresentation(subpath, sub, sizeof sub);
    if (!sub[0]) {
        CFStringRef desc = ColorSyncProfileCopyDescriptionString(profile);
        if (desc) {
            CFStringGetCString(desc, sub, sizeof sub - 4, kCFStringEncodingUTF8);
            CFRelease(desc);
        }
        strlcat(sub[0] ? sub : strcpy(sub, "Profile"), ".icc", sizeof sub);
    }
    char path[PATH_MAX];
    snprintf(path, sizeof path, "%s/%s", dir, sub);
    for (char *s = path + 1; *s; s++)
        if (*s == '/') {
            *s = 0;
            mkdir(path, 0755);
            *s = '/';
        }
    FILE *f = fopen(path, "wb");
    if (!f) {
        set_error(error, -5000 /* afpAccessDenied */);
        return false;
    }
    size_t n;
    const uint8_t *b = cs_profile_bytes(profile, &n);
    bool ok = fwrite(b, 1, n, f) == n;
    fclose(f);
    return ok;
}

bool
ColorSyncProfileUninstall(ColorSyncProfileRef profile, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    char path[PATH_MAX];
    if (!profile || !profile->url || !CFURLGetFileSystemRepresentation(profile->url, true, (UInt8 *)path, sizeof path))
        return false;
    return unlink(path) == 0;
}

bool
ColorSyncProfileWriteToFile(ColorSyncProfileRef prof, CFURLRef url, CFErrorRef *error)
{
    if (error)
        *error = NULL;
    char path[PATH_MAX];
    if (!prof || !url || !CFURLGetFileSystemRepresentation(url, true, (UInt8 *)path, sizeof path))
        return false;
    FILE *f = fopen(path, "wb");
    if (!f)
        return false;
    size_t n;
    const uint8_t *b = cs_profile_bytes(prof, &n);
    bool ok = fwrite(b, 1, n, f) == n;
    fclose(f);
    return ok;
}
