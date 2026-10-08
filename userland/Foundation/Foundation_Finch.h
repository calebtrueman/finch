/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * What Finch's Foundation sources share (docs/design/FOUNDATION.md).
 */
#ifndef FOUNDATION_FINCH_H
#define FOUNDATION_FINCH_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/* Raise `name` with a printf/%@ reason. */
__attribute__((noreturn, visibility("hidden")))
void FinchRaise(NSString *name, const char *format, ...);

/* The abstract-method exception: "-[X sel]: method only defined for
 * abstract class.  Define -[X sel]!" */
__attribute__((noreturn, visibility("hidden")))
void FinchAbstract(id self, SEL _cmd);

/* CFStringCreateWithFormat's format options for a locale argument (NULL
 * for nil: the formats are the same without a locale). */
__attribute__((visibility("hidden")))
CFDictionaryRef FinchFormatOptions(id locale);

/* CFStringCreateWithFormatAndArguments with %@ as Foundation's: the
 * object's -description (a CFBoolean is "1", not CF's "true"). */
__attribute__((visibility("hidden")))
CFStringRef FinchCreateWithFormat(CFDictionaryRef options, CFStringRef format, va_list args);

/* Parse a decimal number in `s` from `start` (NSDecimal.m): the index after
 * it, or NSNotFound if there are no digits there. */
__attribute__((visibility("hidden")))
NSUInteger FinchScanDecimal(NSString *s, NSUInteger start, NSString *separator, NSDecimal *out);

/* Objects that are never freed implement -dealloc without calling super. */
#define FINCH_NO_SUPER_DEALLOC \
    _Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Wobjc-missing-super-calls\"") \
    _Pragma("clang diagnostic pop")

#endif
