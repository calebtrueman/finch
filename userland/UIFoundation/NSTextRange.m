/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * TextKit 2's locations and ranges: NSTextRange, any two NSTextLocations,
 * and NSCountableTextLocation, the offsets NSTextContentStorage hands out.
 *
 * As Apple's (macOS 26): a range whose end precedes its start isn't made;
 * an empty range contains nothing, intersects nothing and adds nothing to a
 * union, but intersecting it with a range around it gives it back; ranges are equal when their
 * locations are (-isEqual:); descriptions are "start...end".
 */
#import "UIFTextKit2.h"

@implementation NSCountableTextLocation {
    NSInteger _index;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)initWithIndex:(NSInteger)index
{
    if ((self = [super init]))
        _index = index;
    return self;
}

- (instancetype)init { return [self initWithIndex:0]; }

- (NSInteger)index { return _index; }

- (NSComparisonResult)compare:(id<NSTextLocation>)location
{
    NSInteger other = UIFLocationIndex(location);
    if (other == NSNotFound)
        return NSOrderedSame;
    return _index < other ? NSOrderedAscending : _index > other ? NSOrderedDescending : NSOrderedSame;
}

- (BOOL)isEqual:(id)object
{
    return object == self ||
           ([object isKindOfClass:[NSCountableTextLocation class]] && ((NSCountableTextLocation *)object)->_index == _index);
}

- (NSUInteger)hash { return (NSUInteger)_index; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (NSString *)description { return [NSString stringWithFormat:@"%ld", (long)_index]; }
- (NSString *)debugDescription { return [NSString stringWithFormat:@"NSCountableTextLocation: %ld", (long)_index]; }

- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeInteger:_index forKey:@"NS.index"]; }

- (instancetype)initWithCoder:(NSCoder *)coder { return [self initWithIndex:[coder decodeIntegerForKey:@"NS.index"]]; }

@end

NSCountableTextLocation *
UIFLocation(NSInteger index)
{
    return [[[NSCountableTextLocation alloc] initWithIndex:index] autorelease];
}

NSTextRange *
UIFRange(NSInteger start, NSInteger end)
{
    return [[[NSTextRange alloc] initWithLocation:UIFLocation(start) endLocation:UIFLocation(end)] autorelease];
}

NSInteger
UIFLocationIndex(id<NSTextLocation> location)
{
    return [(id)location isKindOfClass:[NSCountableTextLocation class]] ? ((NSCountableTextLocation *)location).index
                                                                         : NSNotFound;
}

NSInteger
UIFOffsetOf(NSTextContentManager *tcm, id<NSTextLocation> location)
{
    if (!location)
        return NSNotFound;
    if ([tcm respondsToSelector:@selector(offsetFromLocation:toLocation:)]) {
        id<NSTextLocation> start = tcm.documentRange.location;
        if (start)
            return [tcm offsetFromLocation:start toLocation:location];
    }
    return UIFLocationIndex(location);
}

id<NSTextLocation>
UIFLocationAt(NSTextContentManager *tcm, NSInteger offset)
{
    if ([tcm respondsToSelector:@selector(locationFromLocation:withOffset:)]) {
        id<NSTextLocation> start = tcm.documentRange.location;
        if (start)
            return [tcm locationFromLocation:start withOffset:offset];
    }
    return offset >= 0 ? UIFLocation(offset) : nil;
}

@implementation NSTextRange {
    id<NSTextLocation> _location, _end;
}

static NSComparisonResult
cmp(id<NSTextLocation> a, id<NSTextLocation> b)
{
    return [a compare:b];
}

- (instancetype)initWithLocation:(id<NSTextLocation>)location endLocation:(id<NSTextLocation>)endLocation
{
    if (!(self = [super init]))
        return nil;
    if (!location || (endLocation && cmp(location, endLocation) == NSOrderedDescending)) {
        [self release];
        return nil;
    }
    _location = [(id)location retain];
    _end = [(id)(endLocation ? endLocation : location) retain];
    return self;
}

- (instancetype)initWithLocation:(id<NSTextLocation>)location { return [self initWithLocation:location endLocation:nil]; }

- (void)dealloc
{
    [(id)_location release];
    [(id)_end release];
    [super dealloc];
}

- (id<NSTextLocation>)location { return _location; }
- (id<NSTextLocation>)endLocation { return _end; }
- (BOOL)isEmpty { return cmp(_location, _end) == NSOrderedSame; }

- (BOOL)isEqualToTextRange:(NSTextRange *)textRange
{
    return textRange == self || ([(id)_location isEqual:textRange.location] && [(id)_end isEqual:textRange.endLocation]);
}

- (BOOL)isEqual:(id)object
{
    return [object isKindOfClass:[NSTextRange class]] && [self isEqualToTextRange:object];
}

- (NSUInteger)hash { return [(id)_location hash] ^ ([(id)_end hash] << 7); }

- (BOOL)containsLocation:(id<NSTextLocation>)location
{
    return cmp(_location, location) != NSOrderedDescending && cmp(location, _end) == NSOrderedAscending;
}

- (BOOL)containsRange:(NSTextRange *)textRange
{
    return cmp(_location, textRange.location) != NSOrderedDescending &&
           cmp(textRange.endLocation, _end) != NSOrderedDescending;
}

- (BOOL)intersectsWithTextRange:(NSTextRange *)textRange
{
    if (self.isEmpty || textRange.isEmpty)
        return NO;
    return cmp(_location, textRange.endLocation) == NSOrderedAscending &&
           cmp(textRange.location, _end) == NSOrderedAscending;
}

- (instancetype)textRangeByIntersectingWithTextRange:(NSTextRange *)textRange
{
    id<NSTextLocation> start = cmp(_location, textRange.location) == NSOrderedDescending ? _location : textRange.location;
    id<NSTextLocation> end = cmp(_end, textRange.endLocation) == NSOrderedAscending ? _end : textRange.endLocation;
    NSComparisonResult c = cmp(start, end);
    if (c == NSOrderedDescending || (c == NSOrderedSame && !self.isEmpty && !textRange.isEmpty))
        return nil;
    return [[[NSTextRange alloc] initWithLocation:start endLocation:end] autorelease];
}

- (instancetype)textRangeByFormingUnionWithTextRange:(NSTextRange *)textRange
{
    /* An empty range adds nothing. */
    if (self.isEmpty && !textRange.isEmpty)
        return textRange;
    if (textRange.isEmpty && !self.isEmpty)
        return self;
    id<NSTextLocation> start = cmp(_location, textRange.location) == NSOrderedDescending ? textRange.location : _location;
    id<NSTextLocation> end = cmp(_end, textRange.endLocation) == NSOrderedAscending ? textRange.endLocation : _end;
    return [[[NSTextRange alloc] initWithLocation:start endLocation:end] autorelease];
}

- (NSString *)description { return [NSString stringWithFormat:@"%@...%@", _location, _end]; }
- (NSString *)debugDescription { return [NSString stringWithFormat:@"<NSTextRange: %p %@>", self, self.description]; }

@end
