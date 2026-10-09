/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <AppKit/AppKit.h>
#include <assert.h>
@interface NSView (FinchTest)
- (void)_finchDeliverGestureEvent:(NSEvent *)event selector:(SEL)selector;
@end
@interface GestureTarget : NSObject
@property NSInteger calls;
@property NSGestureRecognizerState lastState;
- (void)gesture:(NSGestureRecognizer *)recognizer;
@end
@implementation GestureTarget
- (void)gesture:(NSGestureRecognizer *)recognizer
{
    self.calls++;
    self.lastState = recognizer.state;
}
@end
static NSEvent *mouse(NSEventType type, CGFloat x, CGFloat y, NSTimeInterval time)
{
    return [NSEvent mouseEventWithType:type
                              location:NSMakePoint(x, y)
                         modifierFlags:0
                             timestamp:time
                          windowNumber:0
                               context:nil
                           eventNumber:1
                            clickCount:1
                              pressure:0];
}
int main(void)
{
    @autoreleasepool {
        NSView *parent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
        NSView *child = [[NSView alloc] initWithFrame:NSMakeRect(10, 10, 50, 50)];
        [parent addSubview:child];
        GestureTarget *target = [GestureTarget new];
        NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc] initWithTarget:target
                                                                                    action:@selector(gesture:)];
        [parent addGestureRecognizer:click];
        assert(click.view == parent && parent.gestureRecognizers.count == 1);
        [parent addGestureRecognizer:click];
        assert(parent.gestureRecognizers.count == 1);
        [child _finchDeliverGestureEvent:mouse(NSEventTypeLeftMouseDown, 15, 15, 1) selector:@selector(mouseDown:)];
        [child _finchDeliverGestureEvent:mouse(NSEventTypeLeftMouseUp, 15, 15, 2) selector:@selector(mouseUp:)];
        assert(target.calls == 1 && target.lastState == NSGestureRecognizerStateRecognized);
        [child addGestureRecognizer:click];
        assert(click.view == child && parent.gestureRecognizers.count == 0);
        click.enabled = NO;
        [child _finchDeliverGestureEvent:mouse(NSEventTypeLeftMouseDown, 15, 15, 3) selector:@selector(mouseDown:)];
        [child _finchDeliverGestureEvent:mouse(NSEventTypeLeftMouseUp, 15, 15, 4) selector:@selector(mouseUp:)];
        assert(target.calls == 1);
        [child removeGestureRecognizer:click];
        assert(!click.view);
        NSPanGestureRecognizer *pan = [[NSPanGestureRecognizer alloc] initWithTarget:target action:@selector(gesture:)];
        [child addGestureRecognizer:pan];
        [child _finchDeliverGestureEvent:mouse(NSEventTypeLeftMouseDown, 15, 15, 5) selector:@selector(mouseDown:)];
        [child _finchDeliverGestureEvent:mouse(NSEventTypeLeftMouseDragged, 25, 35, 6)
                                selector:@selector(mouseDragged:)];
        assert(target.lastState == NSGestureRecognizerStateBegan);
        NSPoint delta = [pan translationInView:nil];
        assert(delta.x == 10 && delta.y == 20);
        [child _finchDeliverGestureEvent:mouse(NSEventTypeLeftMouseUp, 25, 35, 7) selector:@selector(mouseUp:)];
        assert(target.lastState == NSGestureRecognizerStateEnded);
        __block NSInteger accessoryCalls = 0;
        NSSliderAccessory *a =
            [NSSliderAccessory accessoryWithImage:[[[NSImage alloc] initWithSize:NSMakeSize(4, 4)] autorelease]];
        assert(a.enabled && a.behavior == [NSSliderAccessoryBehavior automaticBehavior]);
        a.behavior = [NSSliderAccessoryBehavior behaviorWithHandler:^(NSSliderAccessory *sender) {
          accessoryCalls++;
        }];
        [a.behavior handleAction:a];
        a.enabled = NO;
        [a.behavior handleAction:a];
        assert(accessoryCalls == 1 && NSSliderAccessoryWidthDefault == 36);
        NSHelpManager *help = NSHelpManager.sharedHelpManager;
        [help setContextHelp:[[[NSAttributedString alloc] initWithString:@"help"] autorelease] forObject:child];
        assert([[[help contextHelpForObject:child] string] isEqual:@"help"]);
        [help removeContextHelpForObject:child];
        assert(![help contextHelpForObject:child]);
        NSVisualEffectView *effect = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        assert(effect.material == 0 && effect.blendingMode == 0 && effect.state == 0 && !effect.emphasized &&
               !effect.allowsVibrancy);
        effect.material = NSVisualEffectMaterialSidebar;
        assert(effect.material == NSVisualEffectMaterialSidebar);
        [effect release];
        [pan release];
        [click release];
        [target release];
        [child release];
        [parent release];
        puts("appkit-gestures: PASS (ownership, ancestor delivery, click, pan, accessory, help, material)");
    }
    return 0;
}
