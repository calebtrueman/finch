/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSCustomResource: a nib's reference to a named resource (an image, by
 * NSClassName "NSImage" and NSResourceName). Decoding it gives the resource
 * itself, found by name, or nil when there's no such resource.
 */
#import "NSControl_Finch.h"

@interface NSCustomResource : NSObject <NSCoding>
@end

@implementation NSCustomResource

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *cls = [coder decodeObjectForKey:@"NSClassName"];
    NSString *name = [coder decodeObjectForKey:@"NSResourceName"];
    [self release];
    if (![name isKindOfClass:[NSString class]] || ![name length])
        return nil;
    if (!cls || [cls isEqualToString:@"NSImage"])
        return (id)[[NSImage imageNamed:name] retain];
    if ([cls isEqualToString:@"NSColor"])
        return (id)[[NSColor colorNamed:name] retain];
    return nil;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

@end
