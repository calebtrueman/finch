/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSDockTile: an app's (or a minimized window's) tile in the Dock, which on Finch is the
 * Rail. The tile keeps its badge, content view and badge setting; the Rail doesn't draw
 * badges or custom tiles yet. Tiles are 128 points square, as Apple's report.
 */
#import "AppKit_Finch.h"

@implementation NSDockTile {
    __weak id _owner;
    NSView *_contentView;
    NSString *_badgeLabel;
    BOOL _showsBadge;
}

- (instancetype)_finchInitWithOwner:(id)owner
{
    if ((self = [super init])) {
        _owner = owner;
    }
    return self;
}

- (void)dealloc
{
    [_contentView release];
    [_badgeLabel release];
    [super dealloc];
}

- (NSSize)size { return NSMakeSize(128, 128); }
- (id)owner { return _owner; }
- (NSView *)contentView { return _contentView; }
- (void)setContentView:(NSView *)view
{
    [_contentView autorelease];
    _contentView = [view retain];
}
- (void)display {}
- (BOOL)showsApplicationBadge { return _showsBadge; }
- (void)setShowsApplicationBadge:(BOOL)flag { _showsBadge = flag; }
- (NSString *)badgeLabel { return _badgeLabel; }
- (void)setBadgeLabel:(NSString *)label
{
    [_badgeLabel autorelease];
    _badgeLabel = [label copy];
}

@end

static char dock_tile_key;

static NSDockTile *
tile_for(id owner)
{
    NSDockTile *t = objc_getAssociatedObject(owner, &dock_tile_key);
    if (!t) {
        t = [[[NSDockTile alloc] _finchInitWithOwner:owner] autorelease];
        objc_setAssociatedObject(owner, &dock_tile_key, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return t;
}

@implementation NSWindow (FinchDockTile)
- (NSDockTile *)dockTile { return tile_for(self); }
@end

NSDockTile *
FinchApplicationDockTile(NSApplication *app)
{
    return tile_for(app);
}
