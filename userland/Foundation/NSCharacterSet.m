/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSCharacterSet and NSMutableCharacterSet (docs/design/FOUNDATION.md),
 * against the SDK's declarations. The sets are CFCharacterSets, whose class
 * is CoreFoundation's __NSCFCharacterSet (a subclass of
 * NSMutableCharacterSet): the predefined sets are CF's, and +alloc returns a
 * placeholder whose -init... make CFCharacterSets.
 *
 * For subclasses, -characterIsMember: is the primitive, and what CF asks of
 * a set it didn't make (-_expandedCFCharacterSet) is built from it.
 */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>

#include "Foundation_Finch.h"

@interface NSPlaceholderCharacterSet : NSMutableCharacterSet
@end

static NSPlaceholderCharacterSet *placeholder, *mutablePlaceholder;

@implementation NSCharacterSet

+ (void)initialize
{
    if (self == [NSCharacterSet class]) {
        placeholder = class_createInstance([NSPlaceholderCharacterSet class], 0);
        mutablePlaceholder = class_createInstance([NSPlaceholderCharacterSet class], 0);
    }
}

+ (instancetype)allocWithZone:(NSZone *)zone
{
    if (self == [NSCharacterSet class]) return (id)placeholder;
    if (self == [NSMutableCharacterSet class]) return (id)mutablePlaceholder;
    return [super allocWithZone:zone];
}

#define PREDEFINED(NAME, CF) + (NSCharacterSet *)NAME { return (id)CFCharacterSetGetPredefined(CF); }
PREDEFINED(controlCharacterSet, kCFCharacterSetControl)
PREDEFINED(whitespaceCharacterSet, kCFCharacterSetWhitespace)
PREDEFINED(whitespaceAndNewlineCharacterSet, kCFCharacterSetWhitespaceAndNewline)
PREDEFINED(decimalDigitCharacterSet, kCFCharacterSetDecimalDigit)
PREDEFINED(letterCharacterSet, kCFCharacterSetLetter)
PREDEFINED(lowercaseLetterCharacterSet, kCFCharacterSetLowercaseLetter)
PREDEFINED(uppercaseLetterCharacterSet, kCFCharacterSetUppercaseLetter)
PREDEFINED(nonBaseCharacterSet, kCFCharacterSetNonBase)
PREDEFINED(alphanumericCharacterSet, kCFCharacterSetAlphaNumeric)
PREDEFINED(decomposableCharacterSet, kCFCharacterSetDecomposable)
PREDEFINED(illegalCharacterSet, kCFCharacterSetIllegal)
PREDEFINED(punctuationCharacterSet, kCFCharacterSetPunctuation)
PREDEFINED(capitalizedLetterCharacterSet, kCFCharacterSetCapitalizedLetter)
PREDEFINED(symbolCharacterSet, kCFCharacterSetSymbol)
PREDEFINED(newlineCharacterSet, kCFCharacterSetNewline)
#undef PREDEFINED

+ (NSCharacterSet *)characterSetWithRange:(NSRange)r
{
    return [(id)CFCharacterSetCreateWithCharactersInRange(NULL, CFRangeMake((CFIndex)r.location, (CFIndex)r.length)) autorelease];
}
+ (NSCharacterSet *)characterSetWithCharactersInString:(NSString *)s
{
    return [(id)CFCharacterSetCreateWithCharactersInString(NULL, (CFStringRef)s) autorelease];
}
+ (NSCharacterSet *)characterSetWithBitmapRepresentation:(NSData *)data
{
    return [(id)CFCharacterSetCreateWithBitmapRepresentation(NULL, (CFDataRef)data) autorelease];
}
+ (NSCharacterSet *)characterSetWithContentsOfFile:(NSString *)path
{
    NSData *d = [NSData dataWithContentsOfFile:path];
    return d ? [self characterSetWithBitmapRepresentation:d] : nil;
}

- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }
- (void)encodeWithCoder:(NSCoder *)coder { }
+ (BOOL)supportsSecureCoding { return YES; }

- (BOOL)characterIsMember:(unichar)c { FinchAbstract(self, _cmd); }
- (BOOL)longCharacterIsMember:(UTF32Char)c { return c <= 0xFFFF && [self characterIsMember:(unichar)c]; }
- (BOOL)hasMemberInPlane:(uint8_t)plane
{
    if (plane != 0) return NO;
    for (UTF32Char c = 0; c <= 0xFFFF; c++)
        if ([self characterIsMember:(unichar)c]) return YES;
    return NO;
}

/* What CF asks of a set it didn't make: the same set as a CFCharacterSet. */
- (CFCharacterSetRef)_expandedCFCharacterSet
{
    CFMutableCharacterSetRef m = CFCharacterSetCreateMutable(NULL);
    for (UTF32Char c = 0; c <= 0xFFFF; c++)
        if ([self characterIsMember:(unichar)c]) CFCharacterSetAddCharactersInRange(m, CFRangeMake((CFIndex)c, 1));
    return (CFCharacterSetRef)[(id)m autorelease];
}

- (NSCharacterSet *)invertedSet
{
    return [(id)CFCharacterSetCreateInvertedSet(NULL, [self _expandedCFCharacterSet]) autorelease];
}
- (NSData *)bitmapRepresentation
{
    return [(id)CFCharacterSetCreateBitmapRepresentation(NULL, [self _expandedCFCharacterSet]) autorelease];
}
- (BOOL)isSupersetOfSet:(NSCharacterSet *)other
{
    return CFCharacterSetIsSupersetOfSet([self _expandedCFCharacterSet], (CFCharacterSetRef)other);
}

- (id)copyWithZone:(NSZone *)zone { return (id)CFCharacterSetCreateCopy(NULL, [self _expandedCFCharacterSet]); }
- (id)mutableCopyWithZone:(NSZone *)zone { return (id)CFCharacterSetCreateMutableCopy(NULL, [self _expandedCFCharacterSet]); }
- (CFTypeID)_cfTypeID { return CFCharacterSetGetTypeID(); }

@end

@implementation NSMutableCharacterSet

/* The predefined sets, as new mutable copies. */
#define PREDEFINED(NAME) + (NSMutableCharacterSet *)NAME { return [[[NSCharacterSet NAME] mutableCopy] autorelease]; }
PREDEFINED(controlCharacterSet)
PREDEFINED(whitespaceCharacterSet)
PREDEFINED(whitespaceAndNewlineCharacterSet)
PREDEFINED(decimalDigitCharacterSet)
PREDEFINED(letterCharacterSet)
PREDEFINED(lowercaseLetterCharacterSet)
PREDEFINED(uppercaseLetterCharacterSet)
PREDEFINED(nonBaseCharacterSet)
PREDEFINED(alphanumericCharacterSet)
PREDEFINED(decomposableCharacterSet)
PREDEFINED(illegalCharacterSet)
PREDEFINED(punctuationCharacterSet)
PREDEFINED(capitalizedLetterCharacterSet)
PREDEFINED(symbolCharacterSet)
PREDEFINED(newlineCharacterSet)
#undef PREDEFINED

+ (NSMutableCharacterSet *)characterSetWithRange:(NSRange)r
{
    return [[[NSCharacterSet characterSetWithRange:r] mutableCopy] autorelease];
}
+ (NSMutableCharacterSet *)characterSetWithCharactersInString:(NSString *)s
{
    return [[[NSCharacterSet characterSetWithCharactersInString:s] mutableCopy] autorelease];
}
+ (NSMutableCharacterSet *)characterSetWithBitmapRepresentation:(NSData *)data
{
    return [[[NSCharacterSet characterSetWithBitmapRepresentation:data] mutableCopy] autorelease];
}

#define ABSTRACT(SIG) SIG { FinchAbstract(self, _cmd); }
ABSTRACT(- (void)addCharactersInRange:(NSRange)r)
ABSTRACT(- (void)removeCharactersInRange:(NSRange)r)
#undef ABSTRACT

- (void)addCharactersInString:(NSString *)s
{
    for (NSUInteger i = 0; i < [s length]; i++) [self addCharactersInRange:NSMakeRange([s characterAtIndex:i], 1)];
}
- (void)removeCharactersInString:(NSString *)s
{
    for (NSUInteger i = 0; i < [s length]; i++) [self removeCharactersInRange:NSMakeRange([s characterAtIndex:i], 1)];
}
- (void)formUnionWithCharacterSet:(NSCharacterSet *)other
{
    for (UTF32Char c = 0; c <= 0xFFFF; c++)
        if ([other characterIsMember:(unichar)c]) [self addCharactersInRange:NSMakeRange(c, 1)];
}
- (void)formIntersectionWithCharacterSet:(NSCharacterSet *)other
{
    for (UTF32Char c = 0; c <= 0xFFFF; c++)
        if (![other characterIsMember:(unichar)c]) [self removeCharactersInRange:NSMakeRange(c, 1)];
}
- (void)invert
{
    for (UTF32Char c = 0; c <= 0xFFFF; c++) {
        if ([self characterIsMember:(unichar)c]) [self removeCharactersInRange:NSMakeRange(c, 1)];
        else [self addCharactersInRange:NSMakeRange(c, 1)];
    }
}

@end

@implementation NSPlaceholderCharacterSet

- (instancetype)retain { return self; }
- (oneway void)release { }
- (instancetype)autorelease { return self; }
- (NSUInteger)retainCount { return NSUIntegerMax; }
- (void)dealloc { }

- (instancetype)init
{
    if (self == mutablePlaceholder) return (id)CFCharacterSetCreateMutable(NULL);
    return (id)CFCharacterSetCreateWithCharactersInRange(NULL, CFRangeMake(0, 0));
}

@end
