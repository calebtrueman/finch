/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * __NSCFAttributedString: CFAttributedString as an NSMutableAttributedString
 * (Foundation's class, linked upward), as Apple's CoreFoundation has it.
 * Foundation's NSAttributedString builds everything else on these
 * primitives; CF calls them on attributed strings it didn't make
 * (CFAttributedString.c's dispatch).
 */
#include "CFObjCClasses_Finch.h"
#include <CoreFoundation/CFAttributedString.h>

CF_PRIVATE Boolean _CFAttributedStringIsMutable(CFAttributedStringRef attrStr);   /* patch 0003 */
CF_EXPORT int _CFAttributedStringCheckAndReplace(CFMutableAttributedStringRef, CFRange, CFStringRef);
CF_EXPORT int _CFAttributedStringCheckAndReplaceAttributed(CFMutableAttributedStringRef, CFRange, CFAttributedStringRef);
CF_EXPORT int _CFAttributedStringCheckAndSetAttributes(CFMutableAttributedStringRef, CFRange, CFTypeRef, Boolean);
CF_EXPORT int _CFAttributedStringCheckAndSetAttribute(CFMutableAttributedStringRef, CFRange, CFStringRef, CFTypeRef);

@interface __NSCFAttributedString : NSMutableAttributedString
@end

enum { ERR_NONE = 0, ERR_NOT_MUTABLE = 1, ERR_NIL = 2, ERR_BOUNDS = 3 };   /* _CFStringErr* (ForFoundationOnly.h) */

static CFRange
cf_range(NSRange r)
{
    return CFRangeMake((CFIndex)r.location, (CFIndex)r.length);
}

/* Apple's exceptions for CF's error codes. */
static void
check(id self, SEL _cmd, int err, NSRange range)
{
    switch (err) {
    case ERR_NONE: return;
    case ERR_NOT_MUTABLE:
        __CFFinchRaise(NSInvalidArgumentException, "Attempt to mutate immutable object with %s", sel_getName(_cmd));
    case ERR_NIL:
        __CFFinchRaise(NSInvalidArgumentException, "*** " FINCH_METHOD_FMT ": nil value", FINCH_METHOD_ARGS);
    default:
        __CFFinchRaise(NSRangeException, "NSMutableRLEArray replaceObjectsInRange:withObject:length:: Out of bounds");
    }
}

static void
check_index(id self, NSUInteger loc)
{
    if (loc >= (NSUInteger)CFAttributedStringGetLength((CFAttributedStringRef)self))
        __CFFinchRaise(NSRangeException, "NSMutableRLEArray objectAtIndex:effectiveRange:: Out of bounds");
}

@implementation __NSCFAttributedString

FINCH_CF_OBJECT_MEMORY

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    return [objc_getClass("NSMutableAttributedString") allocWithZone:zone];
}


- (Class)classForCoder
{
    return objc_getClass(_CFAttributedStringIsMutable((CFAttributedStringRef)self) ? "NSMutableAttributedString" : "NSAttributedString");
}

- (id)string { return (id)CFAttributedStringGetString((CFAttributedStringRef)self); }
- (NSUInteger)length { return (NSUInteger)CFAttributedStringGetLength((CFAttributedStringRef)self); }

- (id)attributesAtIndex:(NSUInteger)loc effectiveRange:(NSRange *)range
{
    check_index(self, loc);
    CFRange r;
    CFDictionaryRef d = CFAttributedStringGetAttributes((CFAttributedStringRef)self, (CFIndex)loc, &r);
    if (range) *range = NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length);
    return (id)d;
}

- (id)attribute:(id)name atIndex:(NSUInteger)loc effectiveRange:(NSRange *)range
{
    check_index(self, loc);
    CFRange r;
    CFTypeRef v = CFAttributedStringGetAttribute((CFAttributedStringRef)self, (CFIndex)loc, (CFStringRef)name, &r);
    if (range) *range = NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length);
    return (id)v;
}

- (id)attributesAtIndex:(NSUInteger)loc longestEffectiveRange:(NSRange *)range inRange:(NSRange)limit
{
    check_index(self, loc);
    CFRange r;
    CFDictionaryRef d = CFAttributedStringGetAttributesAndLongestEffectiveRange((CFAttributedStringRef)self, (CFIndex)loc, cf_range(limit), &r);
    if (range) *range = NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length);
    return (id)d;
}

- (id)attribute:(id)name atIndex:(NSUInteger)loc longestEffectiveRange:(NSRange *)range inRange:(NSRange)limit
{
    check_index(self, loc);
    CFRange r;
    CFTypeRef v = CFAttributedStringGetAttributeAndLongestEffectiveRange((CFAttributedStringRef)self, (CFIndex)loc, (CFStringRef)name, cf_range(limit), &r);
    if (range) *range = NSMakeRange((NSUInteger)r.location, (NSUInteger)r.length);
    return (id)v;
}

- (void)replaceCharactersInRange:(NSRange)range withString:(id)str
{
    check(self, _cmd, str ? _CFAttributedStringCheckAndReplace((CFMutableAttributedStringRef)self, cf_range(range), (CFStringRef)str) : ERR_NIL, range);
}

- (void)setAttributes:(id)attrs range:(NSRange)range
{
    CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int err = _CFAttributedStringCheckAndSetAttributes((CFMutableAttributedStringRef)self, cf_range(range), attrs ? (CFTypeRef)attrs : empty, true);
    CFRelease(empty);
    check(self, _cmd, err, range);
}

- (void)addAttributes:(id)attrs range:(NSRange)range
{
    if (!attrs) check(self, _cmd, ERR_NIL, range);
    check(self, _cmd, _CFAttributedStringCheckAndSetAttributes((CFMutableAttributedStringRef)self, cf_range(range), (CFTypeRef)attrs, false), range);
}

- (void)addAttribute:(id)name value:(id)value range:(NSRange)range
{
    if (!value) __CFFinchRaise(NSInvalidArgumentException, "NSConcreteMutableAttributedString addAttribute:value:range: nil value");
    check(self, _cmd, _CFAttributedStringCheckAndSetAttribute((CFMutableAttributedStringRef)self, cf_range(range), (CFStringRef)name, (CFTypeRef)value), range);
}

- (void)removeAttribute:(id)name range:(NSRange)range
{
    check(self, _cmd, _CFAttributedStringCheckAndSetAttribute((CFMutableAttributedStringRef)self, cf_range(range), (CFStringRef)name, NULL), range);
}

- (void)replaceCharactersInRange:(NSRange)range withAttributedString:(id)str
{
    check(self, _cmd, _CFAttributedStringCheckAndReplaceAttributed((CFMutableAttributedStringRef)self, cf_range(range), (CFAttributedStringRef)str), range);
}

- (void)beginEditing { CFAttributedStringBeginEditing((CFMutableAttributedStringRef)self); }
- (void)endEditing { CFAttributedStringEndEditing((CFMutableAttributedStringRef)self); }

- (id)copyWithZone:(struct _NSZone *)zone
{
    return (id)CFAttributedStringCreateCopy(NULL, (CFAttributedStringRef)self);
}

- (id)mutableCopyWithZone:(struct _NSZone *)zone
{
    return (id)CFAttributedStringCreateMutableCopy(NULL, 0, (CFAttributedStringRef)self);
}

@end

CF_PRIVATE Class
__CFFinchAttributedStringClass(void)
{
    return [__NSCFAttributedString class];
}
