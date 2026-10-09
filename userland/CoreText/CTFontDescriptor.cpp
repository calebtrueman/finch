/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CTFontDescriptor: font attributes; attributes it doesn't hold are read
 * from the font it names, when that font can be found.
 */
#include "CTInternal.h"

struct __CTFontDescriptor {
    CTRuntimeBase base;
    CFDictionaryRef attributes;
};

static void
desc_finalize(CFTypeRef cf)
{
    struct __CTFontDescriptor *d = (struct __CTFontDescriptor *)cf;
    if (d->attributes)
        CFRelease(d->attributes);
}

static Boolean
desc_equal(CFTypeRef a, CFTypeRef b)
{
    return CFEqual(((CTFontDescriptorRef)a)->attributes, ((CTFontDescriptorRef)b)->attributes);
}

static CFHashCode
desc_hash(CFTypeRef cf)
{
    return CFHash(((CTFontDescriptorRef)cf)->attributes);
}

static CFStringRef
desc_desc(CFTypeRef cf)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("CTFontDescriptor <%p> = %@"), cf, ((CTFontDescriptorRef)cf)->attributes);
}

static const CTRuntimeClass desc_class = {
    0, "CTFontDescriptor", NULL, NULL, desc_finalize, desc_equal, desc_hash, NULL, desc_desc, NULL, NULL, 0,
};
static CFTypeID desc_type;

CFTypeID
CTFontDescriptorGetTypeID(void)
{
    return CTTypeRegister(&desc_class, &desc_type);
}

CTFontDescriptorRef
CTFontDescriptorCreateWithAttributes(CFDictionaryRef attributes)
{
    struct __CTFontDescriptor *d =
        (struct __CTFontDescriptor *)CTTypeCreateInstance(CTFontDescriptorGetTypeID(), sizeof(struct __CTFontDescriptor));
    d->attributes = attributes ? CFDictionaryCreateCopy(NULL, attributes)
                               : CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    return d;
}

CTFontDescriptorRef
CTFontDescriptorCreateWithNameAndSize(CFStringRef name, CGFloat size)
{
    CFMutableDictionaryRef a = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    if (name)
        CFDictionarySetValue(a, kCTFontNameAttribute, name);
    if (size > 0) {
        CFNumberRef n = CFNumberCreate(NULL, kCFNumberCGFloatType, &size);
        CFDictionarySetValue(a, kCTFontSizeAttribute, n);
        CFRelease(n);
    }
    CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(a);
    CFRelease(a);
    return d;
}

CTFontDescriptorRef
CTFontDescriptorCreateCopyWithAttributes(CTFontDescriptorRef original, CFDictionaryRef attributes)
{
    if (!original)
        return NULL;
    CFMutableDictionaryRef a = CFDictionaryCreateMutableCopy(NULL, 0, original->attributes);
    if (attributes) {
        CFIndex n = CFDictionaryGetCount(attributes);
        std::vector<const void *> keys((size_t)n), vals((size_t)n);
        CFDictionaryGetKeysAndValues(attributes, keys.data(), vals.data());
        for (CFIndex i = 0; i < n; i++)
            CFDictionarySetValue(a, keys[(size_t)i], vals[(size_t)i]);
    }
    CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(a);
    CFRelease(a);
    return d;
}

CTFontDescriptorRef
CTFontDescriptorCreateCopyWithFamily(CTFontDescriptorRef original, CFStringRef family)
{
    if (!original || !family)
        return NULL;
    CFMutableDictionaryRef a = CFDictionaryCreateMutableCopy(NULL, 0, original->attributes);
    CFDictionaryRemoveValue(a, kCTFontNameAttribute);
    CFDictionarySetValue(a, kCTFontFamilyNameAttribute, family);
    CTFontDescriptorRef d = CTFontDescriptorCreateWithAttributes(a);
    CFRelease(a);
    return d;
}

CTFontDescriptorRef
CTFontDescriptorCreateCopyWithSymbolicTraits(CTFontDescriptorRef original, CTFontSymbolicTraits value,
                                             CTFontSymbolicTraits mask)
{
    if (!original)
        return NULL;
    CFMutableDictionaryRef traits = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                              &kCFTypeDictionaryValueCallBacks);
    uint32_t v = value & mask;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt32Type, &v);
    CFDictionarySetValue(traits, kCTFontSymbolicTrait, n);
    CFRelease(n);
    CFDictionaryRef add = CFDictionaryCreate(NULL, (const void **)&kCTFontTraitsAttribute, (const void **)&traits, 1,
                                             &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef d = CTFontDescriptorCreateCopyWithAttributes(original, add);
    CFRelease(add);
    CFRelease(traits);
    return d;
}

CTFontDescriptorRef
CTFontDescriptorCreateCopyWithVariation(CTFontDescriptorRef original, CFNumberRef identifier, CGFloat value)
{
    if (!original || !identifier)
        return NULL;
    CFDictionaryRef old = (CFDictionaryRef)CFDictionaryGetValue(original->attributes, kCTFontVariationAttribute);
    CFMutableDictionaryRef var = old ? CFDictionaryCreateMutableCopy(NULL, 0, old)
                                     : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                                 &kCFTypeDictionaryValueCallBacks);
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberCGFloatType, &value);
    CFDictionarySetValue(var, identifier, v);
    CFRelease(v);
    CFDictionaryRef add = CFDictionaryCreate(NULL, (const void **)&kCTFontVariationAttribute, (const void **)&var, 1,
                                             &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef d = CTFontDescriptorCreateCopyWithAttributes(original, add);
    CFRelease(add);
    CFRelease(var);
    return d;
}

CTFontDescriptorRef
CTFontDescriptorCreateCopyWithFeature(CTFontDescriptorRef original, CFNumberRef type, CFNumberRef selector)
{
    return original ? (CTFontDescriptorRef)CFRetain(original) : NULL;
}

CFDictionaryRef
CTFontDescriptorCopyAttributes(CTFontDescriptorRef d)
{
    return d ? (CFDictionaryRef)CFRetain(d->attributes) : NULL;
}

CFTypeRef
CTFontDescriptorCopyAttribute(CTFontDescriptorRef d, CFStringRef attribute)
{
    if (!d || !attribute)
        return NULL;
    CFTypeRef v = CFDictionaryGetValue(d->attributes, attribute);
    if (v)
        return CFRetain(v);
    if (CFEqual(attribute, kCTFontSizeAttribute) || CFEqual(attribute, kCTFontMatrixAttribute))
        return NULL;
    /* from the font it names */
    CFStringRef name = (CFStringRef)CFDictionaryGetValue(d->attributes, kCTFontNameAttribute);
    if (!name)
        return NULL;
    CGFontRef cg = CTFontRegistryCopyGraphicsFont(name);
    if (!cg)
        return NULL;
    CTFontRef f = CTFontCreateWithGraphicsFont(cg, 0, NULL, NULL);
    CFRelease(cg);
    CFTypeRef out = f ? CTFontCopyAttribute(f, attribute) : NULL;
    if (f)
        CFRelease(f);
    return out;
}

CFTypeRef
CTFontDescriptorCopyLocalizedAttribute(CTFontDescriptorRef d, CFStringRef attribute, CFStringRef *language)
{
    if (language)
        *language = NULL;
    return CTFontDescriptorCopyAttribute(d, attribute);
}

CFArrayRef
CTFontDescriptorCreateMatchingFontDescriptors(CTFontDescriptorRef d, CFSetRef mandatoryAttributes)
{
    CTFontDescriptorRef m = CTFontDescriptorCreateMatchingFontDescriptor(d, mandatoryAttributes);
    if (!m)
        return NULL;
    CFArrayRef a = CFArrayCreate(NULL, (const void **)&m, 1, &kCFTypeArrayCallBacks);
    CFRelease(m);
    return a;
}

CTFontDescriptorRef
CTFontDescriptorCreateMatchingFontDescriptor(CTFontDescriptorRef d, CFSetRef mandatoryAttributes)
{
    if (!d)
        return NULL;
    CTFontRef f = CTFontCreateWithFontDescriptor(d, 0, NULL);
    if (!f)
        return NULL;
    CFStringRef ps = CTFontCopyPostScriptName(f);
    CTFontDescriptorRef out = CTFontDescriptorCreateWithNameAndSize(ps, 0);
    if (ps)
        CFRelease(ps);
    CFRelease(f);
    return out;
}

bool
CTFontDescriptorMatchFontDescriptorsWithProgressHandler(CFArrayRef descriptors, CFSetRef mandatoryAttributes,
                                                        CTFontDescriptorProgressHandler progressBlock)
{
    return false;
}
