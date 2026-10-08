/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSURLComponents and NSURLQueryItem, NSString's percent-encoding methods
 * and NSCharacterSet's URL character sets (docs/design/FOUNDATION.md),
 * against the SDK's declarations, over CoreFoundation's URL components
 * (_CFURLComponents, which Apple's CF also has).
 */
#import <Foundation/Foundation.h>

#include "Foundation_Finch.h"

typedef struct __CFURLComponents *CFURLComponentsRef;
CF_EXPORT CFURLComponentsRef _CFURLComponentsCreate(CFAllocatorRef);
CF_EXPORT CFURLComponentsRef _CFURLComponentsCreateWithURL(CFAllocatorRef, CFURLRef, Boolean resolve);
CF_EXPORT CFURLComponentsRef _CFURLComponentsCreateWithString(CFAllocatorRef, CFStringRef);
CF_EXPORT CFURLComponentsRef _CFURLComponentsCreateCopy(CFAllocatorRef, CFURLComponentsRef);
CF_EXPORT CFURLRef _CFURLComponentsCopyURL(CFURLComponentsRef);
CF_EXPORT CFURLRef _CFURLComponentsCopyURLRelativeToURL(CFURLComponentsRef, CFURLRef);
CF_EXPORT CFStringRef _CFURLComponentsCopyString(CFURLComponentsRef);
#define GETSET(Name) \
    CF_EXPORT CFStringRef _CFURLComponentsCopy##Name(CFURLComponentsRef); \
    CF_EXPORT Boolean _CFURLComponentsSet##Name(CFURLComponentsRef, CFStringRef); \
    CF_EXPORT CFStringRef _CFURLComponentsCopyPercentEncoded##Name(CFURLComponentsRef); \
    CF_EXPORT Boolean _CFURLComponentsSetPercentEncoded##Name(CFURLComponentsRef, CFStringRef); \
    CF_EXPORT CFRange _CFURLComponentsGetRangeOf##Name(CFURLComponentsRef);
GETSET(User)
GETSET(Password)
GETSET(Host)
GETSET(Path)
GETSET(Query)
GETSET(Fragment)
#undef GETSET
CF_EXPORT CFStringRef _CFURLComponentsCopyScheme(CFURLComponentsRef);
CF_EXPORT Boolean _CFURLComponentsSetScheme(CFURLComponentsRef, CFStringRef);
CF_EXPORT CFRange _CFURLComponentsGetRangeOfScheme(CFURLComponentsRef);
CF_EXPORT CFNumberRef _CFURLComponentsCopyPort(CFURLComponentsRef);
CF_EXPORT Boolean _CFURLComponentsSetPort(CFURLComponentsRef, CFNumberRef);
CF_EXPORT CFRange _CFURLComponentsGetRangeOfPort(CFURLComponentsRef);
CF_EXPORT CFArrayRef _CFURLComponentsCopyQueryItems(CFURLComponentsRef);
CF_EXPORT void _CFURLComponentsSetQueryItems(CFURLComponentsRef, CFArrayRef names, CFArrayRef values);
CF_EXPORT CFArrayRef _CFURLComponentsCopyPercentEncodedQueryItems(CFURLComponentsRef);
CF_EXPORT Boolean _CFURLComponentsSetPercentEncodedQueryItems(CFURLComponentsRef, CFArrayRef names, CFArrayRef values);
CF_EXPORT const CFStringRef _kCFURLComponentsNameKey;
CF_EXPORT const CFStringRef _kCFURLComponentsValueKey;
CF_EXPORT CFStringRef _CFStringCreateByAddingPercentEncodingWithAllowedCharacters(CFAllocatorRef, CFStringRef, CFCharacterSetRef);
CF_EXPORT CFStringRef _CFStringCreateByRemovingPercentEncoding(CFAllocatorRef, CFStringRef);
CF_EXPORT CFCharacterSetRef _CFURLComponentsGetURLUserAllowedCharacterSet(void);
CF_EXPORT CFCharacterSetRef _CFURLComponentsGetURLPasswordAllowedCharacterSet(void);
CF_EXPORT CFCharacterSetRef _CFURLComponentsGetURLHostAllowedCharacterSet(void);
CF_EXPORT CFCharacterSetRef _CFURLComponentsGetURLPathAllowedCharacterSet(void);
CF_EXPORT CFCharacterSetRef _CFURLComponentsGetURLQueryAllowedCharacterSet(void);
CF_EXPORT CFCharacterSetRef _CFURLComponentsGetURLFragmentAllowedCharacterSet(void);

static id
owned(CFTypeRef cf)
{
    return cf ? [(id)cf autorelease] : nil;
}

/* MARK: - NSURLQueryItem */

@implementation NSURLQueryItem {
    NSString *_name;
    NSString *_value;
}

+ (instancetype)queryItemWithName:(NSString *)name value:(NSString *)value
{
    return [[[self alloc] initWithName:name value:value] autorelease];
}

- (instancetype)initWithName:(NSString *)name value:(NSString *)value
{
    if ((self = [super init])) {
        _name = [name copy];
        _value = [value copy];
    }
    return self;
}

- (void)dealloc { [_name release]; [_value release]; [super dealloc]; }
- (NSString *)name { return _name; }
- (NSString *)value { return _value; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (BOOL)isEqual:(id)o
{
    if (o == self) return YES;
    if (![o isKindOfClass:[NSURLQueryItem class]]) return NO;
    NSURLQueryItem *q = o;
    return [_name isEqualToString:q->_name] && (_value == q->_value || [_value isEqualToString:q->_value]);
}
- (NSUInteger)hash { return [_name hash]; }
- (NSString *)description { return [NSString stringWithFormat:@"<%s %p> {name = %@, value = %@}", object_getClassName(self), self, _name, _value]; }
- (instancetype)initWithCoder:(NSCoder *)c { [self release]; return nil; }
- (void)encodeWithCoder:(NSCoder *)c { }
+ (BOOL)supportsSecureCoding { return YES; }

@end

/* MARK: - NSURLComponents */

static NSArray *
items_from(CFArrayRef dicts)
{
    if (!dicts) return nil;
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *d in (NSArray *)dicts)
        [a addObject:[NSURLQueryItem queryItemWithName:[d objectForKey:(id)_kCFURLComponentsNameKey]
                                                 value:[d objectForKey:(id)_kCFURLComponentsValueKey]]];
    CFRelease(dicts);
    return a;
}

static void
split_items(NSArray *items, CFArrayRef *names, CFArrayRef *values)
{
    NSMutableArray *n = [NSMutableArray array], *v = [NSMutableArray array];
    for (NSURLQueryItem *q in items) {
        [n addObject:[q name]];
        [v addObject:[q value] ? (id)[q value] : (id)[NSNull null]];
    }
    *names = (CFArrayRef)n;
    *values = (CFArrayRef)v;
}

@implementation NSURLComponents {
    CFURLComponentsRef _c;
}

- (instancetype)init
{
    if ((self = [super init])) _c = _CFURLComponentsCreate(NULL);
    return self;
}

- (instancetype)initWithURL:(NSURL *)url resolvingAgainstBaseURL:(BOOL)resolve
{
    if ((self = [super init])) {
        _c = url ? _CFURLComponentsCreateWithURL(NULL, (CFURLRef)url, resolve) : NULL;
        if (!_c) { [self release]; return nil; }
    }
    return self;
}

- (instancetype)initWithString:(NSString *)URLString
{
    if ((self = [super init])) {
        _c = URLString ? _CFURLComponentsCreateWithString(NULL, (CFStringRef)URLString) : NULL;
        if (!_c) { [self release]; return nil; }
    }
    return self;
}

- (instancetype)initWithString:(NSString *)URLString encodingInvalidCharacters:(BOOL)encode
{
    return [self initWithString:URLString];
}

+ (instancetype)componentsWithURL:(NSURL *)url resolvingAgainstBaseURL:(BOOL)resolve
{
    return [[[self alloc] initWithURL:url resolvingAgainstBaseURL:resolve] autorelease];
}
+ (instancetype)componentsWithString:(NSString *)s { return [[[self alloc] initWithString:s] autorelease]; }
+ (instancetype)componentsWithString:(NSString *)s encodingInvalidCharacters:(BOOL)e { return [self componentsWithString:s]; }

- (void)dealloc { if (_c) CFRelease(_c); [super dealloc]; }

- (id)copyWithZone:(NSZone *)zone
{
    NSURLComponents *c = [[[self class] alloc] init];
    CFRelease(c->_c);
    c->_c = _CFURLComponentsCreateCopy(NULL, _c);
    return c;
}

- (NSURL *)URL { return owned(_CFURLComponentsCopyURL(_c)); }
- (NSURL *)URLRelativeToURL:(NSURL *)base { return owned(_CFURLComponentsCopyURLRelativeToURL(_c, (CFURLRef)base)); }
- (NSString *)string { return owned(_CFURLComponentsCopyString(_c)); }

#define ACCESSORS(prop, Prop, Name) \
    - (NSString *)prop { return owned(_CFURLComponentsCopy##Name(_c)); } \
    - (void)set##Prop:(NSString *)v \
    { \
        if (!_CFURLComponentsSet##Name(_c, (CFStringRef)v)) \
            FinchRaise(NSInvalidArgumentException, "*** -[NSURLComponents set" #Prop ":]: invalid characters in " #prop); \
    } \
    - (NSString *)percentEncoded##Prop { return owned(_CFURLComponentsCopyPercentEncoded##Name(_c)); } \
    - (void)setPercentEncoded##Prop:(NSString *)v \
    { \
        if (!_CFURLComponentsSetPercentEncoded##Name(_c, (CFStringRef)v)) \
            FinchRaise(NSInvalidArgumentException, "*** -[NSURLComponents setPercentEncoded" #Prop ":]: invalid characters in " #prop); \
    } \
    - (NSRange)rangeOf##Prop { CFRange r = _CFURLComponentsGetRangeOf##Name(_c); return NSMakeRange(r.location == kCFNotFound ? NSNotFound : (NSUInteger)r.location, (NSUInteger)r.length); }
ACCESSORS(user, User, User)
ACCESSORS(password, Password, Password)
ACCESSORS(host, Host, Host)
ACCESSORS(path, Path, Path)
ACCESSORS(query, Query, Query)
ACCESSORS(fragment, Fragment, Fragment)
#undef ACCESSORS

- (NSString *)encodedHost { return [self percentEncodedHost]; }
- (void)setEncodedHost:(NSString *)h { [self setPercentEncodedHost:h]; }

- (NSString *)scheme { return owned(_CFURLComponentsCopyScheme(_c)); }
- (void)setScheme:(NSString *)s
{
    if (!_CFURLComponentsSetScheme(_c, (CFStringRef)s))
        FinchRaise(NSInvalidArgumentException, "*** -[NSURLComponents setScheme:]: invalid characters in scheme");
}
- (NSRange)rangeOfScheme
{
    CFRange r = _CFURLComponentsGetRangeOfScheme(_c);
    return NSMakeRange(r.location == kCFNotFound ? NSNotFound : (NSUInteger)r.location, (NSUInteger)r.length);
}
- (NSNumber *)port { return owned(_CFURLComponentsCopyPort(_c)); }
- (void)setPort:(NSNumber *)p
{
    if (!_CFURLComponentsSetPort(_c, (CFNumberRef)p))
        FinchRaise(NSInvalidArgumentException, "*** -[NSURLComponents setPort:]: port must be non-negative");
}
- (NSRange)rangeOfPort
{
    CFRange r = _CFURLComponentsGetRangeOfPort(_c);
    return NSMakeRange(r.location == kCFNotFound ? NSNotFound : (NSUInteger)r.location, (NSUInteger)r.length);
}

- (NSArray<NSURLQueryItem *> *)queryItems { return items_from(_CFURLComponentsCopyQueryItems(_c)); }
- (void)setQueryItems:(NSArray<NSURLQueryItem *> *)items
{
    if (!items) { _CFURLComponentsSetQuery(_c, NULL); return; }
    CFArrayRef n, v;
    split_items(items, &n, &v);
    _CFURLComponentsSetQueryItems(_c, n, v);
}
- (NSArray<NSURLQueryItem *> *)percentEncodedQueryItems { return items_from(_CFURLComponentsCopyPercentEncodedQueryItems(_c)); }
- (void)setPercentEncodedQueryItems:(NSArray<NSURLQueryItem *> *)items
{
    if (!items) { _CFURLComponentsSetPercentEncodedQuery(_c, NULL); return; }
    CFArrayRef n, v;
    split_items(items, &n, &v);
    if (!_CFURLComponentsSetPercentEncodedQueryItems(_c, n, v))
        FinchRaise(NSInvalidArgumentException, "*** -[NSURLComponents setPercentEncodedQueryItems:]: invalid characters in query item");
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%s %p> {scheme = %@, user = %@, password = %@, host = %@, port = %@, path = %@, query = %@, fragment = %@}",
        object_getClassName(self), self, [self scheme], [self user], [self password], [self host], [self port], [self path], [self query], [self fragment]];
}

- (BOOL)isEqual:(id)o { return o == self || ([o isKindOfClass:[NSURLComponents class]] && [[self string] isEqual:[o string]]); }
- (NSUInteger)hash { return [[self string] hash]; }

@end

/* MARK: - Percent encoding */

@implementation NSString (NSURLUtilities)

- (NSString *)stringByAddingPercentEncodingWithAllowedCharacters:(NSCharacterSet *)allowed
{
    return owned(_CFStringCreateByAddingPercentEncodingWithAllowedCharacters(NULL, (CFStringRef)self, (CFCharacterSetRef)allowed));
}

- (NSString *)stringByRemovingPercentEncoding
{
    return owned(_CFStringCreateByRemovingPercentEncoding(NULL, (CFStringRef)self));
}

- (NSString *)stringByAddingPercentEscapesUsingEncoding:(NSStringEncoding)enc
{
    return owned(CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)self, NULL, NULL, CFStringConvertNSStringEncodingToEncoding(enc)));
}

- (NSString *)stringByReplacingPercentEscapesUsingEncoding:(NSStringEncoding)enc
{
    return owned(CFURLCreateStringByReplacingPercentEscapesUsingEncoding(NULL, (CFStringRef)self, CFSTR(""), CFStringConvertNSStringEncodingToEncoding(enc)));
}

@end

@implementation NSCharacterSet (NSURLUtilities)
+ (NSCharacterSet *)URLUserAllowedCharacterSet { return (id)_CFURLComponentsGetURLUserAllowedCharacterSet(); }
+ (NSCharacterSet *)URLPasswordAllowedCharacterSet { return (id)_CFURLComponentsGetURLPasswordAllowedCharacterSet(); }
+ (NSCharacterSet *)URLHostAllowedCharacterSet { return (id)_CFURLComponentsGetURLHostAllowedCharacterSet(); }
+ (NSCharacterSet *)URLPathAllowedCharacterSet { return (id)_CFURLComponentsGetURLPathAllowedCharacterSet(); }
+ (NSCharacterSet *)URLQueryAllowedCharacterSet { return (id)_CFURLComponentsGetURLQueryAllowedCharacterSet(); }
+ (NSCharacterSet *)URLFragmentAllowedCharacterSet { return (id)_CFURLComponentsGetURLFragmentAllowedCharacterSet(); }
@end
