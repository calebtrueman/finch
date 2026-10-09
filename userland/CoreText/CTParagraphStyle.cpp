/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CTParagraphStyle and CTTextTab: paragraph settings with Apple's defaults (twelve 28-point tab stops). */
#include "CTParagraphInternal.h"
#include <string.h>

#pragma mark - CTTextTab

struct __CTTextTab {
    CTRuntimeBase base;
    CTTextAlignment alignment;
    double location;
    CFDictionaryRef options;
};

static void
tab_finalize(CFTypeRef cf)
{
    struct __CTTextTab *t = (struct __CTTextTab *)cf;
    if (t->options)
        CFRelease(t->options);
}

static Boolean
tab_equal(CFTypeRef a, CFTypeRef b)
{
    CTTextTabRef x = (CTTextTabRef)a, y = (CTTextTabRef)b;
    return x->alignment == y->alignment && x->location == y->location;
}

static const CTRuntimeClass tab_class = {
    0, "CTTextTab", NULL, NULL, tab_finalize, tab_equal, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID tab_type;

CFTypeID
CTTextTabGetTypeID(void)
{
    return CTTypeRegister(&tab_class, &tab_type);
}

CTTextTabRef
CTTextTabCreate(CTTextAlignment alignment, double location, CFDictionaryRef options)
{
    struct __CTTextTab *t = (struct __CTTextTab *)CTTypeCreateInstance(CTTextTabGetTypeID(), sizeof(struct __CTTextTab));
    t->alignment = alignment;
    t->location = location;
    t->options = options ? CFDictionaryCreateCopy(NULL, options) : NULL;
    return t;
}

CTTextAlignment CTTextTabGetAlignment(CTTextTabRef t) { return t ? t->alignment : kCTTextAlignmentLeft; }
double CTTextTabGetLocation(CTTextTabRef t) { return t ? t->location : 0; }
CFDictionaryRef CTTextTabGetOptions(CTTextTabRef t) { return t ? t->options : NULL; }

#pragma mark - CTParagraphStyle

static void
style_finalize(CFTypeRef cf)
{
    struct __CTParagraphStyle *p = (struct __CTParagraphStyle *)cf;
    if (p->tabs)
        CFRelease(p->tabs);
}

static Boolean
style_equal(CFTypeRef a, CFTypeRef b)
{
    CTParagraphStyleRef x = (CTParagraphStyleRef)a, y = (CTParagraphStyleRef)b;
    return !memcmp(&x->values, &y->values, sizeof x->values) && CFEqual(x->tabs, y->tabs);
}

static const CTRuntimeClass style_class = {
    0, "CTParagraphStyle", NULL, NULL, style_finalize, style_equal, NULL, NULL, NULL, NULL, NULL, 0,
};
static CFTypeID style_type;

CFTypeID
CTParagraphStyleGetTypeID(void)
{
    return CTTypeRegister(&style_class, &style_type);
}

static CFArrayRef
default_tabs(void)
{
    CFMutableArrayRef tabs = CFArrayCreateMutable(NULL, 12, &kCFTypeArrayCallBacks);
    for (int i = 1; i <= 12; i++) {
        CTTextTabRef t = CTTextTabCreate(kCTTextAlignmentLeft, 28.0 * i, NULL);
        CFArrayAppendValue(tabs, t);
        CFRelease(t);
    }
    return tabs;
}

CTParagraphStyleRef
CTParagraphStyleCreate(const CTParagraphStyleSetting *settings, size_t count)
{
    struct __CTParagraphStyle *p =
        (struct __CTParagraphStyle *)CTTypeCreateInstance(CTParagraphStyleGetTypeID(), sizeof(struct __CTParagraphStyle));
    CTParagraphValues &v = p->values;
    v.alignment = kCTTextAlignmentNatural;
    v.line_break = kCTLineBreakByWordWrapping;
    v.direction = kCTWritingDirectionNatural;
    v.max_line_spacing = 1e30;  /* "unlimited" */
    p->tabs = default_tabs();
    for (size_t i = 0; settings && i < count; i++) {
        const CTParagraphStyleSetting &s = settings[i];
        if (!s.value)
            continue;
        auto f = [&](CGFloat *dst) {
            if (s.valueSize == sizeof(CGFloat))
                memcpy(dst, s.value, sizeof(CGFloat));
        };
        switch (s.spec) {
        case kCTParagraphStyleSpecifierAlignment:
            if (s.valueSize == sizeof(CTTextAlignment))
                memcpy(&v.alignment, s.value, sizeof v.alignment);
            break;
        case kCTParagraphStyleSpecifierFirstLineHeadIndent: f(&v.first_indent); break;
        case kCTParagraphStyleSpecifierHeadIndent: f(&v.head_indent); break;
        case kCTParagraphStyleSpecifierTailIndent: f(&v.tail_indent); break;
        case kCTParagraphStyleSpecifierTabStops:
            if (s.valueSize == sizeof(CFArrayRef)) {
                CFArrayRef tabs = *(const CFArrayRef *)s.value;
                CFRelease(p->tabs);
                p->tabs = tabs ? CFArrayCreateCopy(NULL, tabs) : CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
            }
            break;
        case kCTParagraphStyleSpecifierDefaultTabInterval: f(&v.tab_interval); break;
        case kCTParagraphStyleSpecifierLineBreakMode:
            if (s.valueSize == sizeof(CTLineBreakMode))
                memcpy(&v.line_break, s.value, sizeof v.line_break);
            break;
        case kCTParagraphStyleSpecifierLineHeightMultiple: f(&v.line_height_multiple); break;
        case kCTParagraphStyleSpecifierMaximumLineHeight: f(&v.max_line_height); break;
        case kCTParagraphStyleSpecifierMinimumLineHeight: f(&v.min_line_height); break;
        case kCTParagraphStyleSpecifierLineSpacing: f(&v.line_spacing); break;
        case kCTParagraphStyleSpecifierParagraphSpacing: f(&v.paragraph_spacing); break;
        case kCTParagraphStyleSpecifierParagraphSpacingBefore: f(&v.paragraph_spacing_before); break;
        case kCTParagraphStyleSpecifierBaseWritingDirection:
            if (s.valueSize == sizeof(CTWritingDirection))
                memcpy(&v.direction, s.value, sizeof v.direction);
            break;
        case kCTParagraphStyleSpecifierMaximumLineSpacing: f(&v.max_line_spacing); break;
        case kCTParagraphStyleSpecifierMinimumLineSpacing: f(&v.min_line_spacing); break;
        case kCTParagraphStyleSpecifierLineSpacingAdjustment: f(&v.line_spacing_adjustment); break;
        case kCTParagraphStyleSpecifierLineBoundsOptions:
            if (s.valueSize == sizeof(CTLineBoundsOptions))
                memcpy(&v.bounds_options, s.value, sizeof v.bounds_options);
            break;
        default:
            break;
        }
    }
    return p;
}

CTParagraphStyleRef
CTParagraphStyleCreateCopy(CTParagraphStyleRef style)
{
    if (!style)
        return NULL;
    struct __CTParagraphStyle *p =
        (struct __CTParagraphStyle *)CTTypeCreateInstance(CTParagraphStyleGetTypeID(), sizeof(struct __CTParagraphStyle));
    p->values = style->values;
    p->tabs = (CFArrayRef)CFRetain(style->tabs);
    return p;
}

bool
CTParagraphStyleGetValueForSpecifier(CTParagraphStyleRef style, CTParagraphStyleSpecifier spec, size_t size, void *out)
{
    static CTParagraphStyleRef defaults;
    if (!style) {
        if (!defaults)
            defaults = CTParagraphStyleCreate(NULL, 0);
        style = defaults;
    }
    if (!out)
        return false;
    const CTParagraphValues &v = style->values;
    auto put = [&](const void *src, size_t n) {
        if (size != n)
            return false;
        memcpy(out, src, n);
        return true;
    };
    switch (spec) {
    case kCTParagraphStyleSpecifierAlignment: return put(&v.alignment, sizeof v.alignment);
    case kCTParagraphStyleSpecifierFirstLineHeadIndent: return put(&v.first_indent, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierHeadIndent: return put(&v.head_indent, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierTailIndent: return put(&v.tail_indent, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierTabStops: return put(&style->tabs, sizeof(CFArrayRef));
    case kCTParagraphStyleSpecifierDefaultTabInterval: return put(&v.tab_interval, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierLineBreakMode: return put(&v.line_break, sizeof v.line_break);
    case kCTParagraphStyleSpecifierLineHeightMultiple: return put(&v.line_height_multiple, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierMaximumLineHeight: return put(&v.max_line_height, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierMinimumLineHeight: return put(&v.min_line_height, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierLineSpacing: return put(&v.line_spacing, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierParagraphSpacing: return put(&v.paragraph_spacing, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierParagraphSpacingBefore: return put(&v.paragraph_spacing_before, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierBaseWritingDirection: return put(&v.direction, sizeof v.direction);
    case kCTParagraphStyleSpecifierMaximumLineSpacing: return put(&v.max_line_spacing, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierMinimumLineSpacing: return put(&v.min_line_spacing, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierLineSpacingAdjustment: return put(&v.line_spacing_adjustment, sizeof(CGFloat));
    case kCTParagraphStyleSpecifierLineBoundsOptions: return put(&v.bounds_options, sizeof v.bounds_options);
    default: return false;
    }
}
