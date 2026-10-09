/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* NSString's and NSURL's UTType additions (UTAdditions.h). */
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

/* A name gets the type's extension unless its own extension already means a conforming type. */
static NSString *
with_extension(NSString *name, UTType *type)
{
    NSString *ext = [type preferredFilenameExtension];
    NSString *own = [name pathExtension];
    if ([own length] && [[UTType typeWithFilenameExtension:own] conformsToType:type])
        return name;
    return ext ? [name stringByAppendingPathExtension:ext] : name;
}

@implementation NSString (UTAdditions)

- (NSString *)stringByAppendingPathComponent:(NSString *)partialName conformingToType:(UTType *)contentType
{
    return [self stringByAppendingPathComponent:with_extension(partialName, contentType)];
}

- (NSString *)stringByAppendingPathExtensionForType:(UTType *)contentType
{
    NSString *ext = [contentType preferredFilenameExtension];
    return ext ? [self stringByAppendingPathExtension:ext] : self;
}

@end

@implementation NSURL (UTAdditions)

- (NSURL *)URLByAppendingPathComponent:(NSString *)partialName conformingToType:(UTType *)contentType
{
    return [self URLByAppendingPathComponent:with_extension(partialName, contentType)
                                 isDirectory:[contentType conformsToType:[UTType typeWithIdentifier:@"public.directory"]]];
}

- (NSURL *)URLByAppendingPathExtensionForType:(UTType *)contentType
{
    NSString *ext = [contentType preferredFilenameExtension];
    return ext ? [self URLByAppendingPathExtension:ext] : self;
}

@end
