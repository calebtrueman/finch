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

/* Objects that are never freed implement -dealloc without calling super. */
#define FINCH_NO_SUPER_DEALLOC \
    _Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Wobjc-missing-super-calls\"") \
    _Pragma("clang diagnostic pop")

#endif
