/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSPropertyListSerialization, and the property-list file methods of
 * NSArray and NSDictionary, plus NSString's file and URL writing
 * (docs/design/FOUNDATION.md), against the SDK's declarations, over
 * CFPropertyList.
 */
#import <Foundation/Foundation.h>

#include "Foundation_Finch.h"

static NSError *
plist_error(CFErrorRef e)
{
    return e ? [(id)e autorelease] : nil;
}

@implementation NSPropertyListSerialization

+ (BOOL)propertyList:(id)plist isValidForFormat:(NSPropertyListFormat)format
{
    return CFPropertyListIsValid((CFPropertyListRef)plist, (CFPropertyListFormat)format);
}

+ (NSData *)dataWithPropertyList:(id)plist format:(NSPropertyListFormat)format options:(NSPropertyListWriteOptions)opt
                           error:(out NSError **)error
{
    CFErrorRef e = NULL;
    CFDataRef d = CFPropertyListCreateData(NULL, (CFPropertyListRef)plist, (CFPropertyListFormat)format, opt, &e);
    if (!d) {
        if (error) *error = plist_error(e);
        else if (e) CFRelease(e);
        return nil;
    }
    return [(id)d autorelease];
}

+ (NSInteger)writePropertyList:(id)plist toStream:(NSOutputStream *)stream format:(NSPropertyListFormat)format
                       options:(NSPropertyListWriteOptions)opt error:(out NSError **)error
{
    NSData *d = [self dataWithPropertyList:plist format:format options:opt error:error];
    if (!d) return 0;
    return [stream write:[d bytes] maxLength:[d length]];
}

+ (id)propertyListWithData:(NSData *)data options:(NSPropertyListReadOptions)opt format:(NSPropertyListFormat *)format
                     error:(out NSError **)error
{
    CFErrorRef e = NULL;
    CFPropertyListFormat f = 0;
    CFPropertyListRef p = CFPropertyListCreateWithData(NULL, (CFDataRef)data, opt, &f, &e);
    if (!p) {
        if (error) *error = plist_error(e);
        else if (e) CFRelease(e);
        return nil;
    }
    if (format) *format = (NSPropertyListFormat)f;
    return [(id)p autorelease];
}

+ (id)propertyListWithStream:(NSInputStream *)stream options:(NSPropertyListReadOptions)opt format:(NSPropertyListFormat *)format
                       error:(out NSError **)error
{
    NSMutableData *d = [NSMutableData data];
    uint8_t buf[4096];
    NSInteger n;
    while ((n = [stream read:buf maxLength:sizeof(buf)]) > 0) [d appendBytes:buf length:(NSUInteger)n];
    return [self propertyListWithData:d options:opt format:format error:error];
}

+ (NSData *)dataFromPropertyList:(id)plist format:(NSPropertyListFormat)format errorDescription:(out NSString **)errorString
{
    NSError *e = nil;
    NSData *d = [self dataWithPropertyList:plist format:format options:0 error:&e];
    if (!d && errorString) *errorString = [e localizedDescription];
    return d;
}

+ (id)propertyListFromData:(NSData *)data mutabilityOption:(NSPropertyListMutabilityOptions)opt
                    format:(NSPropertyListFormat *)format errorDescription:(out NSString **)errorString
{
    NSError *e = nil;
    id p = [self propertyListWithData:data options:opt format:format error:&e];
    if (!p && errorString) *errorString = [e localizedDescription];
    return p;
}

@end

/* MARK: - Property-list files */

static id
read_plist(NSString *path, NSPropertyListReadOptions opt, Class want)
{
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    id p = [NSPropertyListSerialization propertyListWithData:d options:opt format:NULL error:NULL];
    return [p isKindOfClass:want] ? p : nil;
}

static BOOL
write_plist(id plist, NSString *path, BOOL atomically)
{
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    return d && [d writeToFile:path atomically:atomically];
}

@implementation NSArray (FinchPropertyList)
+ (id)arrayWithContentsOfFile:(NSString *)path { return read_plist(path, 0, [NSArray class]); }
+ (id)arrayWithContentsOfURL:(NSURL *)url { return [url isFileURL] ? read_plist([url path], 0, [NSArray class]) : nil; }
- (id)initWithContentsOfFile:(NSString *)path { [self release]; return [read_plist(path, 0, [NSArray class]) retain]; }
- (id)initWithContentsOfURL:(NSURL *)url { return [self initWithContentsOfFile:[url path]]; }
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)a { return write_plist(self, path, a); }
- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)a { return [url isFileURL] && write_plist(self, [url path], a); }
- (BOOL)writeToURL:(NSURL *)url error:(NSError **)error { return [self writeToURL:url atomically:YES]; }
@end

@implementation NSMutableArray (FinchPropertyList)
+ (id)arrayWithContentsOfFile:(NSString *)path { return read_plist(path, NSPropertyListMutableContainers, [NSArray class]); }
@end

@implementation NSDictionary (FinchPropertyList)
+ (id)dictionaryWithContentsOfFile:(NSString *)path { return read_plist(path, 0, [NSDictionary class]); }
+ (id)dictionaryWithContentsOfURL:(NSURL *)url { return [url isFileURL] ? read_plist([url path], 0, [NSDictionary class]) : nil; }
- (id)initWithContentsOfFile:(NSString *)path { [self release]; return [read_plist(path, 0, [NSDictionary class]) retain]; }
- (id)initWithContentsOfURL:(NSURL *)url { return [self initWithContentsOfFile:[url path]]; }
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)a { return write_plist(self, path, a); }
- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)a { return [url isFileURL] && write_plist(self, [url path], a); }
- (BOOL)writeToURL:(NSURL *)url error:(NSError **)error { return [self writeToURL:url atomically:YES]; }
@end

@implementation NSMutableDictionary (FinchPropertyList)
+ (id)dictionaryWithContentsOfFile:(NSString *)path { return read_plist(path, NSPropertyListMutableContainers, [NSDictionary class]); }
@end

/* MARK: - Strings to and from files */

@implementation NSString (FinchFiles)

- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)useAuxiliaryFile encoding:(NSStringEncoding)enc error:(NSError **)error
{
    NSData *d = [self dataUsingEncoding:enc];
    if (!d) {
        if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInapplicableStringEncodingError userInfo:nil];
        return NO;
    }
    return [d writeToFile:path options:useAuxiliaryFile ? NSDataWritingAtomic : 0 error:error];
}

- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)useAuxiliaryFile encoding:(NSStringEncoding)enc error:(NSError **)error
{
    return [self writeToFile:[url path] atomically:useAuxiliaryFile encoding:enc error:error];
}

- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)useAuxiliaryFile
{
    return [self writeToFile:path atomically:useAuxiliaryFile encoding:NSUTF8StringEncoding error:NULL];
}

+ (instancetype)stringWithContentsOfURL:(NSURL *)url encoding:(NSStringEncoding)enc error:(NSError **)error
{
    return [self stringWithContentsOfFile:[url path] encoding:enc error:error];
}

- (instancetype)initWithContentsOfURL:(NSURL *)url encoding:(NSStringEncoding)enc error:(NSError **)error
{
    return [self initWithContentsOfFile:[url path] encoding:enc error:error];
}

/* Without an encoding: the byte-order mark's, else UTF-8, as Apple's guesses. */
+ (instancetype)stringWithContentsOfFile:(NSString *)path usedEncoding:(NSStringEncoding *)enc error:(NSError **)error
{
    NSData *d = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!d) return nil;
    const unsigned char *b = [d bytes];
    NSStringEncoding e = NSUTF8StringEncoding;
    if ([d length] >= 2 && ((b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF))) e = NSUnicodeStringEncoding;
    if (enc) *enc = e;
    return [[[self alloc] initWithData:d encoding:e] autorelease];
}

@end

@implementation NSData (FinchURL)
+ (instancetype)dataWithContentsOfURL:(NSURL *)url { return [url isFileURL] ? [self dataWithContentsOfFile:[url path]] : nil; }
+ (instancetype)dataWithContentsOfURL:(NSURL *)url options:(NSDataReadingOptions)o error:(NSError **)error
{
    return [self dataWithContentsOfFile:[url path] options:o error:error];
}
- (BOOL)writeToURL:(NSURL *)url atomically:(BOOL)a { return [self writeToFile:[url path] atomically:a]; }
- (BOOL)writeToURL:(NSURL *)url options:(NSDataWritingOptions)o error:(NSError **)error
{
    return [self writeToFile:[url path] options:o error:error];
}
@end
