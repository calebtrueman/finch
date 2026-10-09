/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CGColor: components in a colour space, plus alpha (or a pattern). */
#include "CGColorInternal.h"
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

extern "C" {
const CFStringRef kCGColorWhite = CFSTR("kCGColorWhite");
const CFStringRef kCGColorBlack = CFSTR("kCGColorBlack");
const CFStringRef kCGColorClear = CFSTR("kCGColorClear");
}

static void
color_finalize(CFTypeRef cf)
{
    struct CGColor *c = (struct CGColor *)cf;
    if (c->space)
        CFRelease(c->space);
    if (c->pattern)
        CFRelease(c->pattern);
}

static Boolean
color_equal(CFTypeRef a, CFTypeRef b)
{
    return CGColorEqualToColor((CGColorRef)a, (CGColorRef)b);
}

static CFHashCode
color_hash(CFTypeRef cf)
{
    CGColorRef c = (CGColorRef)cf;
    CFHashCode h = c->n;
    for (size_t i = 0; i < c->n; i++)
        h = h * 31 + (CFHashCode)(c->comps[i] * 1000);
    return h;
}

static CFStringRef
color_desc(CFTypeRef cf)
{
    CGColorRef c = (CGColorRef)cf;
    CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
    CFStringRef space = CGColorSpaceCopyDebugDescription(c->space);
    CFStringAppendFormat(s, NULL, CFSTR("<CGColor %p> [%@]"), c, space);
    CFRelease(space);
    if (c->space->model == kCGColorSpaceModelRGB) {
        if (c->headroom == 0)
            CFStringAppend(s, CFSTR(" headroom unknown"));
        else
            CFStringAppendFormat(s, NULL, CFSTR(" headroom = %f"), c->headroom);
    }
    CFStringAppend(s, CFSTR(" ("));
    for (size_t i = 0; i < c->n; i++)
        CFStringAppendFormat(s, NULL, CFSTR(" %g"), c->comps[i]);
    CFStringAppend(s, CFSTR(" )"));
    return s;
}

static const CGRuntimeClass color_class = {
    0, "CGColor", NULL, NULL, color_finalize, color_equal, color_hash, NULL, color_desc, NULL, NULL, 0,
};
static CFTypeID color_type;

CFTypeID
CGColorGetTypeID(void)
{
    return CGTypeRegister(&color_class, &color_type);
}

static struct CGColor *
color_new(CGColorSpaceRef space, const CGFloat *comps, size_t n)
{
    struct CGColor *c = (struct CGColor *)CGTypeCreateInstance(CGColorGetTypeID(), sizeof(struct CGColor));
    c->space = (CGColorSpaceRef)CFRetain(space);
    c->n = n;
    for (size_t i = 0; i < n && i < CG_COLOR_MAX_COMPONENTS; i++)
        c->comps[i] = comps[i];
    c->headroom = space->extended ? 0 : 1;
    return c;
}

CGColorRef
CGColorCreate(CGColorSpaceRef space, const CGFloat *components)
{
    if (!space || !components || space->kind == CG_SPACE_PATTERN || space->n + 1 > CG_COLOR_MAX_COMPONENTS)
        return NULL;
    return color_new(space, components, space->n + 1);
}

static CGColorRef
create_named(CFStringRef name, const CGFloat *comps, bool clamp)
{
    CGColorSpaceRef space = CGColorSpaceCreateWithName(name);
    CGFloat v[CG_COLOR_MAX_COMPONENTS];
    size_t n = space->n + 1;
    for (size_t i = 0; i < n; i++)
        v[i] = clamp ? fmin(1, fmax(0, comps[i])) : comps[i];
    CGColorRef c = color_new(space, v, n);
    CFRelease(space);
    return c;
}

CGColorRef
CGColorCreateGenericGray(CGFloat gray, CGFloat alpha)
{
    CGFloat v[2] = {gray, alpha};
    return create_named(kCGColorSpaceGenericGray, v, true);
}

CGColorRef
CGColorCreateGenericRGB(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha)
{
    CGFloat v[4] = {red, green, blue, alpha};
    return create_named(kCGColorSpaceGenericRGB, v, true);
}

CGColorRef
CGColorCreateGenericCMYK(CGFloat cyan, CGFloat magenta, CGFloat yellow, CGFloat black, CGFloat alpha)
{
    CGFloat v[5] = {cyan, magenta, yellow, black, alpha};
    return create_named(kCGColorSpaceGenericCMYK, v, true);
}

CGColorRef
CGColorCreateGenericGrayGamma2_2(CGFloat gray, CGFloat alpha)
{
    CGFloat v[2] = {gray, alpha};
    return create_named(kCGColorSpaceGenericGrayGamma2_2, v, true);
}

CGColorRef
CGColorCreateSRGB(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha)
{
    CGFloat v[4] = {red, green, blue, alpha};
    return create_named(kCGColorSpaceSRGB, v, true);
}

CGColorRef
CGColorCreateWithContentHeadroom(float headroom, CGColorSpaceRef space, CGFloat red, CGFloat green, CGFloat blue,
                                 CGFloat alpha)
{
    if (!space || space->model != kCGColorSpaceModelRGB)
        return NULL;
    CGFloat v[4] = {red, green, blue, alpha};
    struct CGColor *c = color_new(space, v, 4);
    c->headroom = headroom;
    return c;
}

float
CGColorGetContentHeadroom(CGColorRef c)
{
    return c ? c->headroom : 0;
}

static pthread_mutex_t constants_lock = PTHREAD_MUTEX_INITIALIZER;

CGColorRef
CGColorGetConstantColor(CFStringRef name)
{
    static CGColorRef white, black, clear;
    if (!name)
        return NULL;
    CGColorRef *slot;
    CGFloat v[2];
    if (CFEqual(name, kCGColorWhite))
        slot = &white, v[0] = 1, v[1] = 1;
    else if (CFEqual(name, kCGColorBlack))
        slot = &black, v[0] = 0, v[1] = 1;
    else if (CFEqual(name, kCGColorClear))
        slot = &clear, v[0] = 0, v[1] = 0;
    else
        return NULL;
    pthread_mutex_lock(&constants_lock);
    if (!*slot)
        *slot = create_named(kCGColorSpaceGenericGrayGamma2_2, v, false);
    pthread_mutex_unlock(&constants_lock);
    return *slot;
}

CGColorRef
CGColorCreateWithPattern(CGColorSpaceRef space, CGPatternRef pattern, const CGFloat *components)
{
    if (!space || space->kind != CG_SPACE_PATTERN || !pattern)
        return NULL;
    CGFloat v[CG_COLOR_MAX_COMPONENTS] = {0};
    size_t n = space->n + 1;
    for (size_t i = 0; i < n; i++)
        v[i] = components ? components[i] : (i == n - 1 ? 1 : 0);
    if (!space->base_space)
        v[0] = components ? components[0] : 1;
    struct CGColor *c = color_new(space, v, space->base_space ? n : 1);
    c->pattern = (CGPatternRef)CFRetain(pattern);
    return c;
}

CGColorRef
CGColorCreateCopy(CGColorRef c)
{
    return c ? (CGColorRef)CFRetain(c) : NULL;
}

CGColorRef
CGColorCreateCopyWithAlpha(CGColorRef c, CGFloat alpha)
{
    if (!c)
        return NULL;
    struct CGColor *copy = color_new(c->space, c->comps, c->n);
    copy->comps[c->n - 1] = alpha;
    copy->headroom = c->headroom;
    if (c->pattern)
        copy->pattern = (CGPatternRef)CFRetain(c->pattern);
    return copy;
}

CGColorRef
CGColorCreateCopyByMatchingToColorSpace(CGColorSpaceRef space, CGColorRenderingIntent intent, CGColorRef c,
                                        CFDictionaryRef options)
{
    if (!space || !c || c->pattern || space->kind == CG_SPACE_PATTERN || space->kind == CG_SPACE_INDEXED)
        return NULL;
    CGColorSpaceRef dst = CGColorSpaceResolveDevice(space);
    CGFloat out[CG_COLOR_MAX_COMPONENTS];
    CGColorSpaceConvertComponents(c->space, c->comps, dst, out);
    out[dst->n] = c->comps[c->n - 1];
    CGColorRef result = color_new(dst, out, dst->n + 1);
    CFRelease(dst);
    return result;
}

CGColorRef
CGColorRetain(CGColorRef c)
{
    return c ? (CGColorRef)CFRetain(c) : NULL;
}

void
CGColorRelease(CGColorRef c)
{
    if (c)
        CFRelease(c);
}

bool
CGColorEqualToColor(CGColorRef a, CGColorRef b)
{
    if (a == b)
        return true;
    if (!a || !b || a->n != b->n || a->pattern != b->pattern)
        return false;
    if (a->space != b->space && !CFEqual(a->space, b->space))
        return false;
    for (size_t i = 0; i < a->n; i++)
        if (a->comps[i] != b->comps[i])
            return false;
    return true;
}

size_t
CGColorGetNumberOfComponents(CGColorRef c)
{
    return c ? c->n : 0;
}

const CGFloat *
CGColorGetComponents(CGColorRef c)
{
    return c ? c->comps : NULL;
}

CGFloat
CGColorGetAlpha(CGColorRef c)
{
    return c ? c->comps[c->n - 1] : 0;
}

CGColorSpaceRef
CGColorGetColorSpace(CGColorRef c)
{
    return c ? c->space : NULL;
}

CGPatternRef
CGColorGetPattern(CGColorRef c)
{
    return c ? c->pattern : NULL;
}

void
CGColorGetRGBA(CGColorRef c, CGColorSpaceRef target, CGFloat out[4])
{
    CGFloat v[CG_COLOR_MAX_COMPONENTS];
    CGColorSpaceConvertComponents(c->space, c->comps, target, v);
    out[0] = v[0], out[1] = v[1], out[2] = v[2];
    out[3] = c->comps[c->n - 1];
}
