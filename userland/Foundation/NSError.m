/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSError (docs/design/FOUNDATION.md), against the SDK's declaration, with
 * Apple's ivars (_reserved, _code, _domain, _userInfo). Descriptions follow
 * Apple's wording: "Error Domain=D Code=C \"description\" UserInfo={...}",
 * POSIX errors described by strerror, others "The operation couldn’t be
 * completed. (D error C.)" unless the user info says otherwise.
 * Toll-free bridging with CFError comes with the class CF gives CFErrors.
 */
#import <Foundation/Foundation.h>
#include <string.h>

#include "Foundation_Finch.h"

@implementation NSError {
    void *_reserved;
    NSInteger _code;
    NSString *_domain;
    NSDictionary *_userInfo;
}

+ (instancetype)errorWithDomain:(NSErrorDomain)domain code:(NSInteger)code userInfo:(NSDictionary<NSErrorUserInfoKey, id> *)dict
{
    return [[[self alloc] initWithDomain:domain code:code userInfo:dict] autorelease];
}

- (instancetype)initWithDomain:(NSErrorDomain)domain code:(NSInteger)code userInfo:(NSDictionary<NSErrorUserInfoKey, id> *)dict
{
    if (!domain)
        FinchRaise(NSInvalidArgumentException, "*** -[NSError initWithDomain:code:userInfo:]: nil domain");
    if ((self = [super init])) {
        _domain = [domain copy];
        _code = code;
        _userInfo = [dict copy];
    }
    return self;
}

- (void)dealloc
{
    [_domain release];
    [_userInfo release];
    [super dealloc];
}

- (NSErrorDomain)domain { return _domain; }
- (NSInteger)code { return _code; }
- (NSDictionary<NSErrorUserInfoKey, id> *)userInfo { return _userInfo ? _userInfo : @{}; }

- (NSString *)localizedDescription
{
    NSString *d = [_userInfo objectForKey:NSLocalizedDescriptionKey];
    if (d) return d;
    NSString *reason = [self localizedFailureReason];
    if (reason) return [@"The operation couldn’t be completed. " stringByAppendingString:reason];
    return [NSString stringWithFormat:@"The operation couldn’t be completed. (%@ error %ld.)", _domain, (long)_code];
}

- (NSString *)localizedFailureReason
{
    NSString *r = [_userInfo objectForKey:NSLocalizedFailureReasonErrorKey];
    if (r) return r;
    if ([_domain isEqualToString:NSPOSIXErrorDomain] && _code > 0 && _code < 1000)
        return [NSString stringWithUTF8String:strerror((int)_code)];
    return nil;
}

- (NSString *)localizedRecoverySuggestion { return [_userInfo objectForKey:NSLocalizedRecoverySuggestionErrorKey]; }
- (NSArray<NSString *> *)localizedRecoveryOptions { return [_userInfo objectForKey:NSLocalizedRecoveryOptionsErrorKey]; }
- (id)recoveryAttempter { return [_userInfo objectForKey:NSRecoveryAttempterErrorKey]; }
- (NSString *)helpAnchor { return [_userInfo objectForKey:NSHelpAnchorErrorKey]; }
- (NSArray<NSError *> *)underlyingErrors
{
    NSError *u = [_userInfo objectForKey:NSUnderlyingErrorKey];
    return u ? @[ u ] : @[];
}

- (NSString *)description
{
    NSString *d = [_userInfo objectForKey:NSLocalizedDescriptionKey];
    if (!d) d = [self localizedFailureReason];
    NSMutableString *s = [NSMutableString stringWithFormat:@"Error Domain=%@ Code=%ld", _domain, (long)_code];
    if (d) [s appendFormat:@" \"%@\"", d];
    if ([_userInfo count]) {
        [s appendString:@" UserInfo={"];
        NSUInteger i = 0;
        for (id k in _userInfo) [s appendFormat:@"%@%@=%@", i++ ? @", " : @"", k, [_userInfo objectForKey:k]];
        [s appendString:@"}"];
    }
    return s;
}

- (BOOL)isEqual:(id)other
{
    if (other == self) return YES;
    if (![other isKindOfClass:[NSError class]]) return NO;
    NSError *o = other;
    return _code == o->_code && [_domain isEqualToString:o->_domain] &&
        (_userInfo == o->_userInfo || [[self userInfo] isEqual:[o userInfo]]);
}

- (NSUInteger)hash { return [_domain hash] ^ (NSUInteger)_code; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (instancetype)initWithCoder:(NSCoder *)coder { [self release]; return nil; }
- (void)encodeWithCoder:(NSCoder *)coder { }
+ (BOOL)supportsSecureCoding { return YES; }

@end

NSErrorUserInfoKey const NSLocalizedFailureReasonErrorKey = @"NSLocalizedFailureReason";
NSErrorUserInfoKey const NSLocalizedRecoverySuggestionErrorKey = @"NSLocalizedRecoverySuggestion";
NSErrorUserInfoKey const NSLocalizedRecoveryOptionsErrorKey = @"NSLocalizedRecoveryOptions";
NSErrorUserInfoKey const NSRecoveryAttempterErrorKey = @"NSRecoveryAttempter";
NSErrorUserInfoKey const NSHelpAnchorErrorKey = @"NSHelpAnchor";
NSErrorUserInfoKey const NSStringEncodingErrorKey = @"NSStringEncodingErrorKey";
NSErrorUserInfoKey const NSURLErrorKey = @"NSURL";
