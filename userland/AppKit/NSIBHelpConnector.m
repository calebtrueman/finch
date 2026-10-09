/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSIBHelpConnector: a nib connection carrying help for an object; ibtool
 * writes tool tips this way (NSFile "NSToolTipHelpKey", NSMarker the tip).
 * NSIBObjectData treats it as any connector: -source, -destination,
 * -replaceObject:withObject:, then -establishConnection.
 */
#import "AppKit_Finch.h"

@interface NSIBHelpConnector : NSObject <NSCoding>
@end

@implementation NSIBHelpConnector {
    id _destination;
    NSString *_file, *_marker;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        _destination = [[coder decodeObjectForKey:@"NSDestination"] retain];
        _file = [[coder decodeObjectForKey:@"NSFile"] copy];
        _marker = [[coder decodeObjectForKey:@"NSMarker"] copy];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_destination forKey:@"NSDestination"];
    [coder encodeObject:_file forKey:@"NSFile"];
    [coder encodeObject:_marker forKey:@"NSMarker"];
}

- (void)dealloc
{
    [_destination release];
    [_file release];
    [_marker release];
    [super dealloc];
}

- (id)source { return nil; }
- (id)destination { return _destination; }
- (NSString *)label { return _file; }

- (void)replaceObject:(id)old withObject:(id)new
{
    if (_destination == old) {
        [new retain];
        [_destination release];
        _destination = new;
    }
}

- (void)establishConnection
{
    if ([_file isEqualToString:@"NSToolTipHelpKey"] && [_destination respondsToSelector:@selector(setToolTip:)])
        [_destination setToolTip:_marker];
}

@end
