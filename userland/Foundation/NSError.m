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

/* Apple's descriptions of the Cocoa errors, with the file ("f.txt"), its
 * folder ("dir") or the invalid value from the user info when there is one. */
static NSString *
cocoa_description(NSInteger code, NSDictionary *info)
{
    NSString *path = [info objectForKey:NSFilePathErrorKey];
    if (!path) path = [[info objectForKey:NSURLErrorKey] path];
    NSString *file = [path lastPathComponent], *folder = [[path stringByDeletingLastPathComponent] lastPathComponent];
    id value = [info objectForKey:@"NSInvalidValue"];
#define WITH_FILE(with, without) return file ? [NSString stringWithFormat:with, file] : without
    switch (code) {
    case NSFileNoSuchFileError: WITH_FILE(@"The file “%@” doesn’t exist.", @"The file doesn’t exist.");
    case NSFileReadUnknownError: WITH_FILE(@"The file “%@” couldn’t be opened.", @"The file couldn’t be opened.");
    case NSFileReadNoPermissionError:
        WITH_FILE(@"The file “%@” couldn’t be opened because you don’t have permission to view it.",
            @"The file couldn’t be opened because you don’t have permission to view it.");
    case NSFileReadCorruptFileError:
        WITH_FILE(@"The file “%@” couldn’t be opened because it isn’t in the correct format.",
            @"The file couldn’t be opened because it isn’t in the correct format.");
    case NSFileReadNoSuchFileError:
        WITH_FILE(@"The file “%@” couldn’t be opened because there is no such file.", @"The file couldn’t be opened because it doesn’t exist.");
    case NSFileReadInapplicableStringEncodingError: return @"The file couldn’t be opened using the specified text encoding.";
    case NSFileReadUnknownStringEncodingError:
        WITH_FILE(@"The file “%@” couldn’t be opened because the text encoding of its contents can’t be determined.",
            @"The file couldn’t be opened because the text encoding of the contents couldn’t be determined.");
    case NSFileWriteUnknownError:
        return file ? [NSString stringWithFormat:@"The file “%@” couldn’t be saved in the folder “%@”.", file, folder] : @"The file couldn’t be saved.";
    case NSFileWriteNoPermissionError:
        return file ? [NSString stringWithFormat:@"You don’t have permission to save the file “%@” in the folder “%@”.", file, folder]
                    : @"The file couldn’t be saved because you don’t have permission.";
    case NSFileWriteInvalidFileNameError:
        WITH_FILE(@"The item couldn’t be saved because the file name “%@” is invalid.", @"The item couldn’t be saved because the file name is invalid.");
    case NSFileWriteFileExistsError:
        return file ? [NSString stringWithFormat:@"The file “%@” couldn’t be saved in the folder “%@” because a file with the same name already exists.", file, folder]
                    : @"The file couldn’t be saved because a file with the same name already exists.";
    case NSFileWriteOutOfSpaceError:
        WITH_FILE(@"You can’t save the file “%@” because there isn’t enough space.", @"The file couldn’t be saved because there isn’t enough space.");
    case NSFileWriteVolumeReadOnlyError:
        WITH_FILE(@"You can’t save the file “%@” because the volume is read only.", @"The file couldn’t be saved because the volume is read only.");
    case NSFormattingError: return value ? [NSString stringWithFormat:@"The value “%@” is invalid.", value] : @"The value is invalid.";
    case NSUserCancelledError: return @"The operation was cancelled.";
    case NSPropertyListReadCorruptError: return @"The data couldn’t be read because it isn’t in the correct format.";
    case NSPropertyListWriteStreamError: return @"The data couldn’t be written because of an error in the destination for the data.";
    case NSCoderReadCorruptError: return @"The data couldn’t be read because it isn’t in the correct format.";
    case NSCoderValueNotFoundError: return @"The data couldn’t be read because it is missing.";
    case NSCoderInvalidValueError: return @"The data couldn’t be written because it isn’t in the correct format.";
    default: return nil;
    }
#undef WITH_FILE
}

- (NSString *)localizedDescription
{
    NSString *d = [_userInfo objectForKey:NSLocalizedDescriptionKey];
    if (d) return d;
    if ([_domain isEqualToString:NSCocoaErrorDomain] && (d = cocoa_description(_code, _userInfo))) return d;
    NSString *reason = [self localizedFailureReason];
    if (reason) return [@"The operation couldn’t be completed. " stringByAppendingString:reason];
    NSString *domain = [_domain isEqualToString:NSCocoaErrorDomain] ? @"Cocoa" : _domain;
    return [NSString stringWithFormat:@"The operation couldn’t be completed. (%@ error %ld.)", domain, (long)_code];
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
    /* Apple's: POSIX errors by strerror even over the user info, then the
     * user info's description or failure reason, else "(null)". */
    NSString *d = nil;
    if ([_domain isEqualToString:NSPOSIXErrorDomain] && _code > 0 && _code < 1000) d = [NSString stringWithUTF8String:strerror((int)_code)];
    if (!d) d = [_userInfo objectForKey:NSLocalizedDescriptionKey];
    if (!d && [_domain isEqualToString:NSCocoaErrorDomain]) d = cocoa_description(_code, _userInfo);
    if (!d) d = [self localizedFailureReason];
    NSMutableString *s = [NSMutableString stringWithFormat:@"Error Domain=%@ Code=%ld \"%@\"", _domain, (long)_code, d ? d : @"(null)"];
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
+ (BOOL)supportsSecureCoding { return YES; }

@end

NSErrorUserInfoKey const NSLocalizedFailureReasonErrorKey = @"NSLocalizedFailureReason";
NSErrorUserInfoKey const NSLocalizedRecoverySuggestionErrorKey = @"NSLocalizedRecoverySuggestion";
NSErrorUserInfoKey const NSLocalizedRecoveryOptionsErrorKey = @"NSLocalizedRecoveryOptions";
NSErrorUserInfoKey const NSRecoveryAttempterErrorKey = @"NSRecoveryAttempter";
NSErrorUserInfoKey const NSHelpAnchorErrorKey = @"NSHelpAnchor";
NSErrorUserInfoKey const NSStringEncodingErrorKey = @"NSStringEncodingErrorKey";
NSErrorUserInfoKey const NSURLErrorKey = @"NSURL";
NSErrorUserInfoKey const NSDebugDescriptionErrorKey = @"NSDebugDescription";
NSErrorUserInfoKey const NSLocalizedFailureErrorKey = @"NSLocalizedFailure";
NSErrorUserInfoKey const NSMultipleUnderlyingErrorsKey = @"NSMultipleUnderlyingErrorsKey";
