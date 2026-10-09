/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSFontDescriptor over CoreText. As on macOS, an NSFontDescriptor is a
 * CTFontDescriptor (bridged to NSCTFontDescriptor, a subclass of
 * UIFontDescriptor, a subclass of NSFontDescriptor), and its attribute keys
 * are CoreText's.
 */
#import "UIFoundationInternal.h"
#import <objc/runtime.h>

extern void _CFRuntimeBridgeTypeToClass(CFTypeID typeID, const void *cls);
extern CFTypeRef _CFTryRetain(CFTypeRef cf);
extern Boolean _CFIsDeallocating(CFTypeRef cf);

static NSString *const kCTMatrixKey = @"NSCTFontMatrixAttribute";
static NSString *const kDesignTraitKey = @"NSCTFontUIFontDesignTrait";

static NSFontDescriptor *
descriptor_with(NSDictionary *attributes)
{
    return [(NSFontDescriptor *)CTFontDescriptorCreateWithAttributes((CFDictionaryRef)(attributes ? attributes : @{}))
        autorelease];
}

/* [NSFontDescriptor alloc] gets this; -initWithFontAttributes: returns a CTFontDescriptor. */
@interface NSFontDescriptorPlaceholder : NSFontDescriptor
@end

@implementation NSFontDescriptor

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    static NSFontDescriptorPlaceholder *placeholder;
    if (self == [NSFontDescriptor class] || self == [UIFontDescriptor class] || self == [NSCTFontDescriptor class]) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            placeholder = (NSFontDescriptorPlaceholder *)class_createInstance([NSFontDescriptorPlaceholder class], 0);
        });
        return placeholder;
    }
    return [super allocWithZone:zone];
}

+ (BOOL)supportsSecureCoding { return YES; }

+ (NSFontDescriptor *)fontDescriptorWithFontAttributes:(NSDictionary *)attributes
{
    return descriptor_with(attributes);
}

+ (NSFontDescriptor *)fontDescriptorWithName:(NSString *)fontName size:(CGFloat)size
{
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    if (fontName)
        a[NSFontNameAttribute] = fontName;
    a[NSFontSizeAttribute] = @(size);
    return descriptor_with(a);
}

/* The matrix attributes: AppKit's (an NSAffineTransform) and CoreText's (six doubles). */
static void
add_matrix(NSMutableDictionary *a, NSAffineTransform *matrix)
{
    if (!matrix)
        return;
    NSAffineTransformStruct t = matrix.transformStruct;
    CGAffineTransform m = CGAffineTransformMake(t.m11, t.m12, t.m21, t.m22, t.tX, t.tY);
    a[kCTMatrixKey] = [NSData dataWithBytes:&m length:sizeof m];
    a[NSFontMatrixAttribute] = [[matrix copy] autorelease];
}

+ (NSFontDescriptor *)fontDescriptorWithName:(NSString *)fontName matrix:(NSAffineTransform *)matrix
{
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    if (fontName)
        a[NSFontNameAttribute] = fontName;
    add_matrix(a, matrix);
    return descriptor_with(a);
}

static CGFloat
text_style_size(NSString *style, BOOL *bold)
{
    static const struct {
        NSString *style;
        CGFloat size;
        BOOL bold;
    } sizes[] = {
        {@"UICTFontTextStyleTitle0", 26, NO}, {@"UICTFontTextStyleTitle1", 22, NO},
        {@"UICTFontTextStyleTitle2", 17, NO}, {@"UICTFontTextStyleTitle3", 15, NO},
        {@"UICTFontTextStyleHeadline", 13, YES}, {@"UICTFontTextStyleSubhead", 11, NO},
        {@"UICTFontTextStyleBody", 13, NO}, {@"UICTFontTextStyleCallout", 12, NO},
        {@"UICTFontTextStyleFootnote", 10, NO}, {@"UICTFontTextStyleCaption1", 10, NO},
        {@"UICTFontTextStyleCaption2", 10, NO},
    };
    for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++)
        if ([style isEqual:sizes[i].style]) {
            *bold = sizes[i].bold;
            return sizes[i].size;
        }
    *bold = NO;
    return 13;
}

+ (NSFontDescriptor *)preferredFontDescriptorForTextStyle:(NSFontTextStyle)style options:(NSDictionary *)options
{
    BOOL bold;
    CGFloat size = text_style_size(style, &bold);
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    a[@"NSCTFontSizeCategoryAttribute"] = @3;
    a[UIFUIUsageAttribute] = style ? style : @"UICTFontTextStyleBody";
    a[NSFontSizeAttribute] = @(size);
    if (bold)
        a[NSFontNameAttribute] = @".AppleSystemUIFaceHeadline";
    return descriptor_with(a);
}

- (CTFontDescriptorRef)_ctDescriptor { return (CTFontDescriptorRef)self; }

- (NSDictionary *)fontAttributes
{
    return [(NSDictionary *)CTFontDescriptorCopyAttributes(self._ctDescriptor) autorelease];
}

- (id)objectForKey:(NSFontDescriptorAttributeName)attribute
{
    return [(id)CTFontDescriptorCopyAttribute(self._ctDescriptor, (CFStringRef)attribute) autorelease];
}

- (NSString *)postscriptName
{
    id n = self.fontAttributes[NSFontNameAttribute];
    return [n isKindOfClass:[NSString class]] ? n : nil;
}

- (CGFloat)pointSize
{
    id s = self.fontAttributes[NSFontSizeAttribute];
    return [s respondsToSelector:@selector(doubleValue)] ? [s doubleValue] : 0;
}

- (NSAffineTransform *)matrix
{
    NSDictionary *a = self.fontAttributes;
    id m = a[NSFontMatrixAttribute];
    if ([m isKindOfClass:[NSAffineTransform class]])
        return m;
    NSData *d = a[kCTMatrixKey];
    if ([d isKindOfClass:[NSData class]] && d.length == sizeof(CGAffineTransform)) {
        CGAffineTransform t;
        memcpy(&t, d.bytes, sizeof t);
        NSAffineTransform *x = [NSAffineTransform transform];
        x.transformStruct = (NSAffineTransformStruct){t.a, t.b, t.c, t.d, t.tx, t.ty};
        return x;
    }
    return nil;
}

- (NSFontDescriptorSymbolicTraits)symbolicTraits
{
    NSDictionary *traits = [self objectForKey:NSFontTraitsAttribute];
    if ([traits isKindOfClass:[NSDictionary class]])
        return (NSFontDescriptorSymbolicTraits)[traits[NSFontSymbolicTrait] unsignedIntValue];
    return 0;
}

- (BOOL)requiresFontAssetRequest { return NO; }

- (NSFontDescriptor *)fontDescriptorByAddingAttributes:(NSDictionary *)attributes
{
    NSMutableDictionary *a = [[self.fontAttributes mutableCopy] autorelease];
    [a addEntriesFromDictionary:attributes];
    return descriptor_with(a);
}

- (NSFontDescriptor *)fontDescriptorWithSize:(CGFloat)newPointSize
{
    return [self fontDescriptorByAddingAttributes:@{NSFontSizeAttribute : @(newPointSize)}];
}

- (NSFontDescriptor *)fontDescriptorWithMatrix:(NSAffineTransform *)matrix
{
    NSMutableDictionary *a = [[self.fontAttributes mutableCopy] autorelease];
    add_matrix(a, matrix);
    return descriptor_with(a);
}

- (NSFontDescriptor *)fontDescriptorWithFace:(NSString *)newFace
{
    NSMutableDictionary *a = [[self.fontAttributes mutableCopy] autorelease];
    [a removeObjectForKey:NSFontNameAttribute];
    a[NSFontFaceAttribute] = newFace;
    return descriptor_with(a);
}

- (NSFontDescriptor *)fontDescriptorWithFamily:(NSString *)newFamily
{
    NSMutableDictionary *a = [[self.fontAttributes mutableCopy] autorelease];
    [a removeObjectForKey:NSFontNameAttribute];
    a[NSFontFamilyAttribute] = newFamily;
    return descriptor_with(a);
}

- (NSFontDescriptor *)fontDescriptorWithSymbolicTraits:(NSFontDescriptorSymbolicTraits)symbolicTraits
{
    NSDictionary *attrs = self.fontAttributes;
    NSString *usage = attrs[UIFUIUsageAttribute];
    id size = attrs[NSFontSizeAttribute];
    if (usage) {
        /* The system font's emphasized (bold) and regular faces. */
        NSMutableDictionary *a = [NSMutableDictionary dictionary];
        if (symbolicTraits & NSFontDescriptorTraitBold) {
            a[UIFUIUsageAttribute] = @"CTFontEmphasizedUsage";
            a[NSFontNameAttribute] = @".AppleSystemUIFontEmphasized";
        } else {
            a[UIFUIUsageAttribute] = @"CTFontRegularUsage";
        }
        if (size)
            a[NSFontSizeAttribute] = size;
        return descriptor_with(a);
    }
    if (!attrs[NSFontNameAttribute]) {
        NSMutableDictionary *a = [[attrs mutableCopy] autorelease];
        NSMutableDictionary *traits = [[attrs[NSFontTraitsAttribute] mutableCopy] autorelease];
        if (![traits isKindOfClass:[NSMutableDictionary class]])
            traits = [NSMutableDictionary dictionary];
        traits[NSFontSymbolicTrait] = @(symbolicTraits);
        a[NSFontTraitsAttribute] = traits;
        return descriptor_with(a);
    }
    /* A named font: its family's face with these traits, if it has one. */
    CTFontRef f = CTFontCreateWithFontDescriptor(self._ctDescriptor, 0, NULL);
    if (!f)
        return nil;
    CTFontSymbolicTraits mask = kCTFontTraitBold | kCTFontTraitItalic | kCTFontTraitCondensed | kCTFontTraitExpanded;
    CTFontRef t = CTFontCreateCopyWithSymbolicTraits(f, 0, NULL, (CTFontSymbolicTraits)symbolicTraits, mask);
    CFRelease(f);
    if (!t)
        return nil;
    CTFontSymbolicTraits got = CTFontGetSymbolicTraits(t);
    NSString *ps = [(NSString *)CTFontCopyPostScriptName(t) autorelease];
    CFRelease(t);
    if ((got & mask & symbolicTraits) != (mask & symbolicTraits))
        return nil;
    NSMutableDictionary *a = [NSMutableDictionary dictionaryWithObject:ps forKey:NSFontNameAttribute];
    if (size)
        a[NSFontSizeAttribute] = size;
    return descriptor_with(a);
}

- (instancetype)fontDescriptorWithDesign:(NSFontDescriptorSystemDesign)design
{
    /* Only the system font has designs. */
    NSDictionary *attrs = self.fontAttributes;
    NSString *usage = attrs[UIFUIUsageAttribute];
    if (!usage || !design)
        return nil;
    NSFont *f = UIFSystemFontForUsage(usage, self.pointSize);
    NSDictionary *fontTraits = [(NSDictionary *)CTFontCopyTraits((CTFontRef)f) autorelease];
    NSMutableDictionary *traits = [NSMutableDictionary dictionary];
    traits[NSFontWidthTrait] = fontTraits[NSFontWidthTrait] ? fontTraits[NSFontWidthTrait] : @0;
    traits[NSFontSlantTrait] = fontTraits[NSFontSlantTrait] ? fontTraits[NSFontSlantTrait] : @0;
    traits[NSFontSymbolicTrait] = @(kCTFontTraitUIOptimized | (CTFontGetSymbolicTraits((CTFontRef)f) & kCTFontTraitBold));
    traits[kDesignTraitKey] = design;
    traits[NSFontWeightTrait] = fontTraits[NSFontWeightTrait] ? fontTraits[NSFontWeightTrait] : @0;
    NSMutableDictionary *a = [NSMutableDictionary dictionaryWithObject:traits forKey:NSFontTraitsAttribute];
    if (attrs[NSFontSizeAttribute])
        a[NSFontSizeAttribute] = attrs[NSFontSizeAttribute];
    return descriptor_with(a);
}

/* What a descriptor matches: the installed font it resolves to, if that
 * font has the family, face and name the descriptor asks for. */
- (NSFontDescriptor *)matchingFontDescriptorWithMandatoryKeys:(NSSet *)mandatoryKeys
{
    NSDictionary *attrs = self.fontAttributes;
    NSString *usage = attrs[UIFUIUsageAttribute];
    CTFontRef f = usage ? (CTFontRef)[UIFSystemFontForUsage(usage, 0) retain]
                        : CTFontCreateWithFontDescriptor(self._ctDescriptor, 0, NULL);
    if (!f)
        return nil;
    NSString *ps = [(NSString *)CTFontCopyPostScriptName(f) autorelease];
    NSString *family = [(NSString *)CTFontCopyFamilyName(f) autorelease];
    NSString *face = [(NSString *)CTFontCopyName(f, kCTFontStyleNameKey) autorelease];
    BOOL ok = YES;
    NSString *want = attrs[NSFontFamilyAttribute];
    if (want && [want caseInsensitiveCompare:family] != NSOrderedSame)
        ok = NO;
    want = attrs[NSFontFaceAttribute];
    if (want && face && [want caseInsensitiveCompare:face] != NSOrderedSame)
        ok = NO;
    want = attrs[NSFontNameAttribute];
    if (want && !usage && ![NSFont fontWithName:want size:12])
        ok = NO;
    if (ok && attrs[NSFontTraitsAttribute]) {
        NSNumber *sym = attrs[NSFontTraitsAttribute][NSFontSymbolicTrait];
        CTFontSymbolicTraits w = sym.unsignedIntValue & (kCTFontTraitBold | kCTFontTraitItalic);
        if (w && (CTFontGetSymbolicTraits(f) & w) != w)
            ok = NO;
    }
    CFRelease(f);
    if (!ok || !ps)
        return nil;
    return descriptor_with(@{NSFontNameAttribute : ps});
}

- (NSArray *)matchingFontDescriptorsWithMandatoryKeys:(NSSet *)mandatoryKeys
{
    NSFontDescriptor *d = [self matchingFontDescriptorWithMandatoryKeys:mandatoryKeys];
    return d ? @[ d ] : @[];
}

#pragma mark Copying, coding, equality, description

- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (Class)classForCoder { return [NSFontDescriptor class]; }
- (Class)classForKeyedArchiver { return [NSFontDescriptor class]; }
- (id)replacementObjectForKeyedArchiver:(NSKeyedArchiver *)archiver { return self; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    NSMutableDictionary *a = [[self.fontAttributes mutableCopy] autorelease];
    [a removeObjectForKey:kCTMatrixKey];
    if (coder.allowsKeyedCoding) {
        [coder encodeObject:a forKey:@"NSFontDescriptorAttributes"];
        [coder encodeInteger:(NSInteger)0x80000000u forKey:@"NSFontDescriptorOptions"];
    } else {
        [coder encodeObject:a];
    }
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSDictionary *a;
    if (coder.allowsKeyedCoding) {
        NSSet *classes = [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSString class], [NSNumber class],
                                               [NSData class], [NSAffineTransform class], [NSCharacterSet class], nil];
        a = [coder decodeObjectOfClasses:classes forKey:@"NSFontDescriptorAttributes"];
    } else {
        a = [coder decodeObject];
    }
    NSMutableDictionary *m = [[a mutableCopy] autorelease];
    if ([m[NSFontMatrixAttribute] isKindOfClass:[NSAffineTransform class]])
        add_matrix(m, m[NSFontMatrixAttribute]);
    NSFontDescriptor *d = descriptor_with(m);
    if (d != self)
        [self release];
    return [d retain];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"%s <%p> = %@", object_getClassName(self), self, self.fontAttributes];
}

@end

@implementation NSFontDescriptorPlaceholder
- (instancetype)retain { return self; }
- (oneway void)release { }
- (instancetype)autorelease { return self; }
- (NSUInteger)retainCount { return NSUIntegerMax; }
- (void)dealloc { }
- (instancetype)init { return (id)[descriptor_with(nil) retain]; }
- (instancetype)initWithFontAttributes:(NSDictionary *)attributes { return (id)[descriptor_with(attributes) retain]; }
@end

@implementation UIFontDescriptor
@end

/* CTFontDescriptor's class. Memory, equality and hashing are CoreFoundation's. */
@implementation NSCTFontDescriptor

+ (void)load
{
    _CFRuntimeBridgeTypeToClass(CTFontDescriptorGetTypeID(), (const void *)self);
}

- (instancetype)retain { return (id)CFRetain((CFTypeRef)self); }
- (oneway void)release { CFRelease((CFTypeRef)self); }
- (NSUInteger)retainCount { return (NSUInteger)CFGetRetainCount((CFTypeRef)self); }
- (BOOL)_tryRetain { return _CFTryRetain((CFTypeRef)self) != NULL; }
- (BOOL)_isDeallocating { return _CFIsDeallocating((CFTypeRef)self); }
- (BOOL)allowsWeakReference { return !_CFIsDeallocating((CFTypeRef)self); }
- (BOOL)retainWeakReference { return _CFTryRetain((CFTypeRef)self) != NULL; }
- (CFTypeID)_cfTypeID { return CFGetTypeID((CFTypeRef)self); }
- (void)dealloc { }
- (NSUInteger)hash { return (NSUInteger)CFHash((CFTypeRef)self); }
- (BOOL)isEqual:(id)other
{
    if (other == self)
        return YES;
    if (![other isKindOfClass:[NSCTFontDescriptor class]])
        return NO;
    return CFEqual((CFTypeRef)self, (CFTypeRef)other);
}

@end

@interface NSMutableFontDescriptor : NSFontDescriptor
@end
@implementation NSMutableFontDescriptor
@end
