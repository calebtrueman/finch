/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* NSTrackingArea: a rect of a view whose owner hears when the pointer enters, leaves or moves in it. */
#import "NSView_Finch.h"

@implementation NSTrackingArea {
    NSRect _rect;
    NSTrackingAreaOptions _options;
    id _owner;  /* not retained, as Apple's */
    NSDictionary *_userInfo;
    NSView *_view;  /* not retained */
    BOOL _inside;   /* whether the pointer was in it at the last move (NSWindow) */
}

- (instancetype)initWithRect:(NSRect)rect options:(NSTrackingAreaOptions)options owner:(id)owner
                    userInfo:(NSDictionary *)userInfo
{
    self = [super init];
    if (self) {
        _rect = rect;
        _options = options;
        _owner = owner;
        _userInfo = [userInfo copy];
    }
    return self;
}

- (void)dealloc
{
    [_userInfo release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[NSTrackingArea alloc] initWithRect:_rect options:_options owner:_owner userInfo:_userInfo];
}

- (NSRect)rect
{
    if ((_options & NSTrackingInVisibleRect) && _view)
        return [_view visibleRect];
    return _rect;
}

- (NSTrackingAreaOptions)options { return _options; }
- (id)owner { return _owner; }
- (NSDictionary *)userInfo { return _userInfo; }
- (void)_finchSetView:(NSView *)view { _view = view; }
- (NSView *)_finchView { return _view; }
- (BOOL)_finchInside { return _inside; }
- (void)_finchSetInside:(BOOL)inside { _inside = inside; }

@end
