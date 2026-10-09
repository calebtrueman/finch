/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>

@interface FinchMiscResponder : NSResponder
@end
@implementation FinchMiscResponder
- (NSTouchBar *)makeTouchBar
{
    NSTouchBar *bar = [[[NSTouchBar alloc] init] autorelease];
    bar.defaultItemIdentifiers = @[@"custom"];
    return bar;
}
@end

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        puts("AppKit animation, Touch Bar and help comparison");
        NSAnimationContext *base = NSAnimationContext.currentContext;
        base.duration = .7;
        [NSAnimationContext beginGrouping];
        printf("group same=%d duration=%.2f\n", base == NSAnimationContext.currentContext, NSAnimationContext.currentContext.duration);
        NSAnimationContext.currentContext.duration = .3;
        [NSAnimationContext beginGrouping];
        NSAnimationContext.currentContext.duration = .1;
        [NSAnimationContext endGrouping];
        printf("nested restored=%.2f\n", NSAnimationContext.currentContext.duration);
        [NSAnimationContext endGrouping];
        printf("outer same=%d restored=%.2f\n", base == NSAnimationContext.currentContext, base.duration);
        __block BOOL completed = NO;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) { context.duration = 0; }
            completionHandler:^{ completed = YES; }];
        printf("completion immediate=%d\n", completed);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, .05, false);
        printf("completion later=%d\n", completed);
        NSView *view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)] autorelease];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0;
            [[view animator] setFrameOrigin:NSMakePoint(7, 8)];
        }];
        printf("animator cached=%d proxy=%d frame=%.0f,%.0f\n", view.animator == view.animator,
            [view.animator isProxy], view.frame.origin.x, view.frame.origin.y);
        for (int curve = 0; curve < 4; curve++) {
            NSAnimation *animation = [[[NSAnimation alloc] initWithDuration:1 animationCurve:curve] autorelease];
            animation.currentProgress = .25;
            printf("curve%d=%.6f\n", curve, animation.currentValue);
        }
        FinchMiscResponder *responder = [[[FinchMiscResponder alloc] init] autorelease];
        printf("responder cached=%d count=%lu\n", responder.touchBar == responder.touchBar,
            (unsigned long)responder.touchBar.defaultItemIdentifiers.count);
        NSTouchBar *bar = [[[NSTouchBar alloc] init] autorelease];
        NSCustomTouchBarItem *custom = [[[NSCustomTouchBarItem alloc] initWithIdentifier:@"custom"] autorelease];
        custom.view = view;
        bar.templateItems = [NSSet setWithObject:custom];
        bar.defaultItemIdentifiers = @[@"custom", NSTouchBarItemIdentifierFlexibleSpace];
        printf("bar template=%d space=%d missing=%d visible=%d items=%lu\n", [bar itemForIdentifier:@"custom"] == custom,
            [bar itemForIdentifier:NSTouchBarItemIdentifierFlexibleSpace] != nil, [bar itemForIdentifier:@"missing"] == nil,
            bar.visible, (unsigned long)bar.itemIdentifiers.count);
        NSPopoverTouchBarItem *popover = [[[NSPopoverTouchBarItem alloc] initWithIdentifier:@"popover"] autorelease];
        printf("popover close=%d bar=%d hold=%d\n", popover.showsCloseButton, popover.popoverTouchBar != nil, popover.pressAndHoldTouchBar != nil);
        NSGroupTouchBarItem *group = [NSGroupTouchBarItem groupItemWithIdentifier:@"group" items:@[custom]];
        printf("group items=%lu\n", (unsigned long)group.groupTouchBar.defaultItemIdentifiers.count);
        NSButtonTouchBarItem *button = [NSButtonTouchBarItem buttonTouchBarItemWithIdentifier:@"button" title:@"Title" target:nil action:NULL];
        printf("button title=%s enabled=%d\n", button.title.UTF8String, button.enabled);
        NSSliderTouchBarItem *slider = [[[NSSliderTouchBarItem alloc] initWithIdentifier:@"slider"] autorelease];
        printf("slider value=%.0f min=%.0f max=%d\n", slider.doubleValue, slider.minimumSliderWidth, slider.maximumSliderWidth == FLT_MAX);
        NSColorPickerTouchBarItem *color = [NSColorPickerTouchBarItem colorPickerWithIdentifier:@"color"];
        printf("color alpha=%d enabled=%d\n", color.showsAlpha, color.enabled);
        NSStepperTouchBarItem *stepper = [NSStepperTouchBarItem stepperTouchBarItemWithIdentifier:@"stepper" formatter:[[[NSNumberFormatter alloc] init] autorelease]];
        printf("stepper max=%.0f increment=%.0f\n", stepper.maxValue, stepper.increment);
        NSTouchBar *saved = [[[NSTouchBar alloc] init] autorelease];
        saved.customizationIdentifier = @"saved";
        saved.defaultItemIdentifiers = @[@"one", @"two"];
        NSData *data = [NSKeyedArchiver archivedDataWithRootObject:saved requiringSecureCoding:NO error:NULL];
        NSTouchBar *restored = [NSKeyedUnarchiver unarchiveObjectWithData:data];
        printf("saved id=%s items=%lu\n", restored.customizationIdentifier.UTF8String, (unsigned long)restored.defaultItemIdentifiers.count);
        NSVisualEffectView *effect = [[[NSVisualEffectView alloc] initWithFrame:NSZeroRect] autorelease];
        printf("effect layer=%d opaque=%d vibrancy=%d\n", effect.wantsLayer, effect.opaque, effect.allowsVibrancy);
        NSClickGestureRecognizer *click = [[[NSClickGestureRecognizer alloc] initWithTarget:nil action:NULL] autorelease];
        NSClickGestureRecognizer *otherClick = [[[NSClickGestureRecognizer alloc] initWithTarget:nil action:NULL] autorelease];
        [view addGestureRecognizer:click];
        [view addGestureRecognizer:otherClick];
        printf("gesture clicks=%ld touches=%ld enabled=%d attached=%d count=%lu\n", (long)click.numberOfClicksRequired,
            (long)click.numberOfTouchesRequired, click.enabled, click.view == view, (unsigned long)view.gestureRecognizers.count);
        [view removeGestureRecognizer:click];
        printf("gesture removed=%d count=%lu\n", click.view == nil, (unsigned long)view.gestureRecognizers.count);
        NSSliderAccessory *accessory = [NSSliderAccessory accessoryWithImage:[[[NSImage alloc] initWithSize:NSMakeSize(10, 10)] autorelease]];
        __block NSInteger actions = 0;
        accessory.behavior = [NSSliderAccessoryBehavior behaviorWithHandler:^(NSSliderAccessory *sender) { actions++; }];
        [accessory.behavior handleAction:accessory];
        printf("accessory enabled=%d actions=%ld width=%.0f\n", accessory.enabled, (long)actions, NSSliderAccessoryWidthDefault);
        NSHelpManager *help = NSHelpManager.sharedHelpManager;
        [help setContextHelp:[[[NSAttributedString alloc] initWithString:@"Help text"] autorelease] forObject:view];
        printf("help=%s\n", [help contextHelpForObject:view].string.UTF8String);
        [help removeContextHelpForObject:view];
        printf("help removed=%d\n", [help contextHelpForObject:view] == nil);
    }
    return 0;
}
