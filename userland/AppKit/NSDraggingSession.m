/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSDraggingSession: a drag in progress, as -beginDraggingSessionWithItems:event:source:
 * returns it. Finch has no drag and drop between views yet; the session keeps its
 * settings and items for when it does.
 */
#import "AppKit_Finch.h"

@implementation NSDraggingSession {
    NSDraggingFormation _formation;
    BOOL _animates;
    NSInteger _leader;
    NSPasteboard *_pasteboard;
    NSInteger _sequence;
    NSPoint _location;
    NSArray<NSDraggingItem *> *_items;
}

- (instancetype)_finchInitWithItems:(NSArray<NSDraggingItem *> *)items location:(NSPoint)location
{
    static NSInteger sequence;
    if ((self = [super init])) {
        _items = [items copy];
        _location = location;
        _pasteboard = [[NSPasteboard pasteboardWithName:NSPasteboardNameDrag] retain];
        _sequence = ++sequence;
        _animates = YES;
    }
    return self;
}

- (void)dealloc
{
    [_items release];
    [_pasteboard release];
    [super dealloc];
}

- (NSDraggingFormation)draggingFormation { return _formation; }
- (void)setDraggingFormation:(NSDraggingFormation)formation { _formation = formation; }
- (BOOL)animatesToStartingPositionsOnCancelOrFail { return _animates; }
- (void)setAnimatesToStartingPositionsOnCancelOrFail:(BOOL)flag { _animates = flag; }
- (NSInteger)draggingLeaderIndex { return _leader; }
- (void)setDraggingLeaderIndex:(NSInteger)index { _leader = index; }
- (NSPasteboard *)draggingPasteboard { return _pasteboard; }
- (NSInteger)draggingSequenceNumber { return _sequence; }
- (NSPoint)draggingLocation { return _location; }

- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)enumOpts forView:(NSView *)view
                                  classes:(NSArray<Class> *)classArray
                            searchOptions:(NSDictionary<NSPasteboardReadingOptionKey, id> *)searchOptions
                               usingBlock:(void (NS_NOESCAPE ^)(NSDraggingItem *draggingItem, NSInteger idx, BOOL *stop))block
{
    BOOL stop = NO;
    NSInteger i = 0;
    for (NSDraggingItem *item in _items) {
        block(item, i++, &stop);
        if (stop)
            break;
    }
}

@end
