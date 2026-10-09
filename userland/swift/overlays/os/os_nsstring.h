// SPDX-License-Identifier: MIT OR Apache-2.0
// What the historical os overlay's format.m needs of Foundation: %s
// arguments arrive from Swift as NSString objects, read with -UTF8String.
// Declared here so libswiftos needs no Foundation, as Apple's doesn't.
#import <objc/NSObject.h>
@interface NSString : NSObject
- (const char *)UTF8String;
@end
