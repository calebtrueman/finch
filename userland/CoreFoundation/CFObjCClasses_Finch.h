/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * What CoreFoundation's own Objective-C classes share (docs/design/FOUNDATION.md):
 * Foundation's types and protocols that CF-hosted classes use, the memory
 * methods every class of CF objects has, and raising exceptions.
 */
#ifndef CF_OBJC_CLASSES_FINCH_H
#define CF_OBJC_CLASSES_FINCH_H

#include "CFInternal.h"
#import <objc/runtime.h>
#import <objc/message.h>

/* <Foundation/NSEnumerator.h>, <Foundation/NSObject.h> */
typedef struct {
    unsigned long state;
    id __unsafe_unretained *itemsPtr;
    unsigned long *mutationsPtr;
    unsigned long extra[5];
} NSFastEnumerationState;

@protocol NSFastEnumeration
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer count:(NSUInteger)len;
@end
@protocol NSCopying
- (id)copyWithZone:(struct _NSZone *)zone;
@end
@protocol NSMutableCopying
- (id)mutableCopyWithZone:(struct _NSZone *)zone;
@end

typedef CF_OPTIONS(NSUInteger, NSEnumerationOptions) {
    NSEnumerationConcurrent = (1UL << 0),
    NSEnumerationReverse = (1UL << 1),
};
#define NSNotFound ((NSInteger)NSIntegerMax)

typedef NSString *NSExceptionName;
CF_EXPORT NSExceptionName const NSGenericException;
CF_EXPORT NSExceptionName const NSRangeException;
CF_EXPORT NSExceptionName const NSInvalidArgumentException;
CF_EXPORT NSExceptionName const NSInternalInconsistencyException;
CF_EXPORT NSExceptionName const NSMallocException;

/* Raise an exception named `name` with a printf/%@ reason. */
CF_PRIVATE void __CFFinchRaise(NSString *name, const char *format, ...) __attribute__((noreturn));

/* "-[__NSCFArray objectAtIndex:]" for the method being run. */
#define FINCH_METHOD_FMT "%c[%s %s]"
#define FINCH_METHOD_ARGS (object_isClass(self) ? '+' : '-'), object_getClassName(self), sel_getName(_cmd)

/* The memory methods of a class whose instances are CF objects: CF counts
 * the references and frees the object (as __NSCFType does). */
#define FINCH_CF_OBJECT_MEMORY \
    - (instancetype)retain { return (id)CFRetain((CFTypeRef)self); } \
    - (oneway void)release { CFRelease((CFTypeRef)self); } \
    - (NSUInteger)retainCount { return (NSUInteger)CFGetRetainCount((CFTypeRef)self); } \
    - (BOOL)_tryRetain { return _CFTryRetain((CFTypeRef)self) != NULL; } \
    - (BOOL)_isDeallocating { return _CFIsDeallocating((CFTypeRef)self); } \
    - (BOOL)allowsWeakReference { return !_CFIsDeallocating((CFTypeRef)self); } \
    - (BOOL)retainWeakReference { return _CFTryRetain((CFTypeRef)self) != NULL; } \
    - (CFTypeID)_cfTypeID { return CFGetTypeID((CFTypeRef)self); } \
    - (void)dealloc { }

/* Objects that live as long as the process (placeholders, singletons). */
#define FINCH_IMMORTAL_MEMORY \
    - (instancetype)retain { return self; } \
    - (oneway void)release { } \
    - (instancetype)autorelease { return self; } \
    - (NSUInteger)retainCount { return NSUIntegerMax; } \
    - (void)dealloc { }

#endif
