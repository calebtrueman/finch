/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "AppKit_Finch.h"
#include <float.h>

NSNotificationName NSDrawerWillOpenNotification = @"NSDrawerWillOpenNotification";
NSNotificationName NSDrawerDidOpenNotification = @"NSDrawerDidOpenNotification";
NSNotificationName NSDrawerWillCloseNotification = @"NSDrawerWillCloseNotification";
NSNotificationName NSDrawerDidCloseNotification = @"NSDrawerDidCloseNotification";
static char drawers_key;
static NSMutableArray *drawer_list(NSWindow *w, BOOL create)
{
    NSMutableArray *a = objc_getAssociatedObject(w, &drawers_key);
    if (!a && create && w) {
        a = [NSMutableArray array];
        objc_setAssociatedObject(w, &drawers_key, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return a;
}

@implementation NSDrawer {
    __weak NSWindow *_parent;
    NSWindow *_window;
    NSView *_content;
    id<NSDrawerDelegate> _delegate;
    NSRectEdge _preferred, _edge;
    NSSize _size, _minSize, _maxSize;
    CGFloat _leading, _trailing;
    NSInteger _state;
}
- (instancetype)init
{
    return [self initWithContentSize:NSMakeSize(200, 200) preferredEdge:NSMinXEdge];
}
- (instancetype)initWithContentSize:(NSSize)s preferredEdge:(NSRectEdge)e
{
    self = [super init];
    if (self) {
        _size = s;
        _preferred = e;
        _edge = (NSRectEdge)(e | 2);
        _trailing = 15;
        _maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
        _content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, s.width, s.height)];
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    self = [self initWithContentSize:[c decodeSizeForKey:@"NSContentSize"]
                       preferredEdge:[c decodeIntegerForKey:@"NSPreferredEdge"]];
    if (self) {
        _minSize = [c decodeSizeForKey:@"NSMinContentSize"];
        if ([c containsValueForKey:@"NSMaxContentSize"])
            _maxSize = [c decodeSizeForKey:@"NSMaxContentSize"];
        _leading = [c decodeDoubleForKey:@"NSLeadingOffset"];
        _trailing = [c decodeDoubleForKey:@"NSTrailingOffset"];
        [self setParentWindow:[c decodeObjectForKey:@"NSParentWindow"]];
        _delegate = [c decodeObjectForKey:@"NSDelegate"];
        NSView *v = [c decodeObjectForKey:@"NSContentView"];
        if (v)
            [self setContentView:v];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c
{
    [super encodeWithCoder:c];
    [c encodeSize:_size forKey:@"NSContentSize"];
    [c encodeSize:_minSize forKey:@"NSMinContentSize"];
    [c encodeSize:_maxSize forKey:@"NSMaxContentSize"];
    [c encodeInteger:_preferred forKey:@"NSPreferredEdge"];
    [c encodeDouble:_leading forKey:@"NSLeadingOffset"];
    [c encodeDouble:_trailing forKey:@"NSTrailingOffset"];
    [c encodeConditionalObject:_parent forKey:@"NSParentWindow"];
    [c encodeConditionalObject:_delegate forKey:@"NSDelegate"];
    [c encodeObject:_content forKey:@"NSContentView"];
}
- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_parent removeChildWindow:_window];
    [_window orderOut:nil];
    [_window release];
    [_content release];
    [super dealloc];
}
- (NSWindow *)parentWindow
{
    return _parent;
}
- (void)setParentWindow:(NSWindow *)v
{
    if (v == _parent)
        return;
    [[self retain] autorelease];
    [self _finchCloseWithoutVeto];
    [drawer_list(_parent, NO) removeObjectIdenticalTo:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _parent = v;
    if (v) {
        [drawer_list(v, YES) addObject:self];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_finchParentClosed:)
                                                     name:NSWindowWillCloseNotification
                                                   object:v];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_finchParentChanged:)
                                                     name:NSWindowDidResizeNotification
                                                   object:v];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_finchParentChanged:)
                                                     name:NSWindowDidMoveNotification
                                                   object:v];
    }
}
- (void)_finchParentClosed:(NSNotification *)n
{
    [self _finchCloseWithoutVeto];
}
- (void)_finchParentChanged:(NSNotification *)n
{
    [self _finchPosition];
}
- (NSView *)contentView
{
    return _content;
}
- (void)setContentView:(NSView *)v
{
    if (v != _content) {
        [_content release];
        _content = [v retain];
        [_window setContentView:v];
    }
}
- (id<NSDrawerDelegate>)delegate
{
    return _delegate;
}
- (void)setDelegate:(id<NSDrawerDelegate>)v
{
    _delegate = v;
}
- (NSRectEdge)preferredEdge
{
    return _preferred;
}
- (void)setPreferredEdge:(NSRectEdge)v
{
    _preferred = v;
}
- (NSRectEdge)edge
{
    return _edge;
}
- (NSInteger)state
{
    return _state;
}
- (NSSize)contentSize
{
    return _size;
}
- (void)setContentSize:(NSSize)v
{
    v.width = MAX(_minSize.width, MIN(_maxSize.width, v.width));
    v.height = MAX(_minSize.height, MIN(_maxSize.height, v.height));
    if ([_delegate respondsToSelector:@selector(drawerWillResizeContents:toSize:)])
        v = [_delegate drawerWillResizeContents:self toSize:v];
    _size = v;
    [self _finchPosition];
}
- (NSSize)minContentSize
{
    return _minSize;
}
- (void)setMinContentSize:(NSSize)v
{
    _minSize = v;
}
- (NSSize)maxContentSize
{
    return _maxSize;
}
- (void)setMaxContentSize:(NSSize)v
{
    _maxSize = v;
}
- (CGFloat)leadingOffset
{
    return _leading;
}
- (void)setLeadingOffset:(CGFloat)v
{
    _leading = v;
    [self _finchPosition];
}
- (CGFloat)trailingOffset
{
    return _trailing;
}
- (void)setTrailingOffset:(CGFloat)v
{
    _trailing = v;
    [self _finchPosition];
}
- (void)_finchPosition
{
    if (!_parent || !_window)
        return;
    NSRect p = [_parent contentRectForFrameRect:[_parent frame]],
           r = NSMakeRect(p.origin.x, p.origin.y, _size.width, _size.height);
    if (_edge == NSMinXEdge || _edge == NSMaxXEdge) {
        r.origin.x = _edge == NSMinXEdge ? NSMinX(p) - r.size.width : NSMaxX(p);
        r.origin.y = NSMinY(p) + _trailing;
        r.size.height = MAX(0, p.size.height - _leading - _trailing);
    } else {
        r.origin.y = _edge == NSMinYEdge ? NSMinY(p) - r.size.height : NSMaxY(p);
        r.origin.x = NSMinX(p) + _leading;
        r.size.width = MAX(0, p.size.width - _leading - _trailing);
    }
    [_window setFrame:r display:YES];
}
- (void)_finchPost:(NSString *)name selector:(SEL)sel
{
    NSNotification *n = [NSNotification notificationWithName:name object:self];
    if ([_delegate respondsToSelector:sel])
        ((void (*)(id, SEL, id))objc_msgSend)(_delegate, sel, n);
    [[NSNotificationCenter defaultCenter] postNotification:n];
}
- (void)open
{
    NSRect parent = [_parent frame], screen = [[_parent screen] visibleFrame];
    NSRectEdge edge = _preferred;
    if (!NSIsEmptyRect(screen)) {
        if (_preferred == NSMinXEdge || _preferred == NSMaxXEdge)
            edge = NSMinX(parent) - NSMinX(screen) > NSMaxX(screen) - NSMaxX(parent) ? NSMinXEdge : NSMaxXEdge;
        else
            edge = NSMinY(parent) - NSMinY(screen) > NSMaxY(screen) - NSMaxY(parent) ? NSMinYEdge : NSMaxYEdge;
    }
    [self openOnEdge:edge];
}
- (void)open:(id)sender
{
    [self open];
}
- (void)openOnEdge:(NSRectEdge)e
{
    if (_state != NSDrawerClosedState || !_parent)
        return;
    if ([_delegate respondsToSelector:@selector(drawerShouldOpen:)] && ![_delegate drawerShouldOpen:self])
        return;
    _edge = e;
    _state = NSDrawerOpeningState;
    [self _finchPost:NSDrawerWillOpenNotification selector:@selector(drawerWillOpen:)];
    if (!_window) {
        _window = [[NSPanel alloc] initWithContentRect:NSZeroRect
                                             styleMask:NSWindowStyleMaskBorderless
                                               backing:NSBackingStoreBuffered
                                                 defer:YES];
        [_window setReleasedWhenClosed:NO];
        [_window setContentView:_content];
    }
    [self _finchPosition];
    [_parent addChildWindow:_window ordered:NSWindowBelow];
    _state = NSDrawerOpenState;
    [self _finchPost:NSDrawerDidOpenNotification selector:@selector(drawerDidOpen:)];
}
- (void)close:(id)sender
{
    [self close];
}
- (void)close
{
    if (_state != NSDrawerOpenState)
        return;
    if ([_delegate respondsToSelector:@selector(drawerShouldClose:)] && ![_delegate drawerShouldClose:self])
        return;
    [self _finchCloseWithoutVeto];
}
- (void)_finchCloseWithoutVeto
{
    if (_state == NSDrawerClosedState)
        return;
    _state = NSDrawerClosingState;
    [self _finchPost:NSDrawerWillCloseNotification selector:@selector(drawerWillClose:)];
    [_parent removeChildWindow:_window];
    [_window orderOut:nil];
    _state = NSDrawerClosedState;
    [self _finchPost:NSDrawerDidCloseNotification selector:@selector(drawerDidClose:)];
}
- (void)toggle:(id)sender
{
    if (_state == NSDrawerClosedState)
        [self open];
    else
        [self close];
}
@end
@implementation NSWindow (FinchDrawers)
- (NSArray *)drawers
{
    return [[drawer_list(self, NO) copy] autorelease] ?: @[];
}
@end
