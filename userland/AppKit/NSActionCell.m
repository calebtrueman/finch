/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* NSActionCell: a cell with a target, an action and a tag of its own. */
#import "NSControl_Finch.h"

@implementation NSActionCell {
    id _target; /* weak, as Apple's */
    SEL _action;
    NSInteger _tag;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self)
        return nil;
    _tag = [coder decodeIntegerForKey:@"NSTag"];
    NSString *action = [coder decodeObjectForKey:@"NSAction"];
    if ([action isKindOfClass:[NSString class]])
        _action = NSSelectorFromString(action);
    _target = [coder decodeObjectForKey:@"NSTarget"];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
    if (_tag)
        [coder encodeInteger:_tag forKey:@"NSTag"];
    if (_action)
        [coder encodeObject:NSStringFromSelector(_action) forKey:@"NSAction"];
    if (_target)
        [coder encodeConditionalObject:_target forKey:@"NSTarget"];
}

- (id)target { return _target; }
- (void)setTarget:(id)target { _target = target; }
- (SEL)action { return _action; }
- (void)setAction:(SEL)action { _action = action; }
- (NSInteger)tag { return _tag; }
- (void)setTag:(NSInteger)tag { _tag = tag; }

@end
