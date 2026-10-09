/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-nib-test: loading a nib compiled by ibtool (nib-test.xib): the
 * objects it makes, their classes and geometry, outlets, awakeFromNib, and
 * the top-level objects. Prints everything; run it against Apple's AppKit
 * and Finch's (DYLD_FRAMEWORK_PATH) and diff.
 *
 *   finch-nib-test [path to nib-test.nib]
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSMutableArray<NSString *> *log_;

@class Controller;

@interface Owner : NSObject
@property (strong) Controller *controller;
@property (strong) NSWindow *window;
@end
@implementation Owner
- (void)awakeFromNib
{
    [log_ addObject:@"Owner awakeFromNib"];
}
@end

@interface Box : NSView
@end
@implementation Box
- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    [log_ addObject:[NSString stringWithFormat:@"Box initWithFrame %@", NSStringFromRect(frame)]];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    [log_ addObject:@"Box initWithCoder"];
    return [super initWithCoder:coder];
}
- (void)awakeFromNib
{
    [log_ addObject:[NSString stringWithFormat:@"Box awakeFromNib window %d subviews %lu", self.window != nil,
                                               (unsigned long)self.subviews.count]];
}
@end

@interface Controller : NSObject
@property (strong) Box *box;
@property (strong) NSView *inner;
@property (weak) Owner *owner;
@end
@implementation Controller
- (instancetype)init
{
    self = [super init];
    [log_ addObject:@"Controller init"];
    return self;
}
- (void)awakeFromNib
{
    [log_ addObject:[NSString stringWithFormat:@"Controller awakeFromNib box %d inner %d owner %d", self.box != nil,
                                               self.inner != nil, self.owner != nil]];
}
@end

static void
dump(NSView *v, int depth)
{
    printf("%*s%s frame %s bounds %s mask %lu autoresizes %d hidden %d flipped %d next %s\n", depth * 2, "",
           class_getName([v class]), NSStringFromRect(v.frame).UTF8String, NSStringFromRect(v.bounds).UTF8String,
           (unsigned long)v.autoresizingMask, v.autoresizesSubviews, v.isHidden, v.isFlipped,
           v.nextResponder ? class_getName([v.nextResponder class]) : "nil");
    for (NSView *s in v.subviews)
        dump(s, depth + 1);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", class_getImageName([NSNib class]));
        [NSApplication sharedApplication];
        log_ = [NSMutableArray array];
        NSString *path = argc > 1 ? @(argv[1]) : @"/usr/local/share/finch/nib-test.nib";
        NSNib *nib = [[NSNib alloc] initWithNibData:[NSData dataWithContentsOfFile:path] bundle:nil];
        printf("nib %d\n", nib != nil);
        Owner *owner = [Owner new];
        NSArray *top = nil;
        BOOL ok = [nib instantiateWithOwner:owner topLevelObjects:&top];
        printf("instantiated %d\n", ok);
        for (NSString *l in log_)
            printf("  %s\n", l.UTF8String);
        NSMutableArray *names = [NSMutableArray array];
        for (id o in top)
            [names addObject:NSStringFromClass([o class])];
        [names sortUsingSelector:@selector(compare:)];
        printf("top level: %s\n", [names componentsJoinedByString:@", "].UTF8String);
        printf("owner.controller %s owner.window %s\n", class_getName([owner.controller class]),
               class_getName([owner.window class]));
        printf("controller in top level %d, window in top level %d\n",
               [top indexOfObjectIdenticalTo:owner.controller] != NSNotFound,
               [top indexOfObjectIdenticalTo:owner.window] != NSNotFound);
        Controller *c = owner.controller;
        printf("controller.owner is owner %d; box is a Box %d; inner superview is box %d\n", c.owner == owner,
               [c.box isKindOfClass:[Box class]], c.inner.superview == c.box);
        NSWindow *w = owner.window;
        printf("window title '%s' frame %s visible %d released %d style %lx shadow %d\n", w.title.UTF8String,
               NSStringFromRect(w.frame).UTF8String, w.isVisible, w.isReleasedWhenClosed,
               (unsigned long)w.styleMask, w.hasShadow);
        printf("content view is window's %d; box window is w %d\n", c.box.superview == w.contentView,
               c.box.window == w);
        dump(w.contentView, 0);
        [w setContentSize:NSMakeSize(580, 300)];
        printf("after resize:\n");
        dump(w.contentView, 0);
    }
    return 0;
}
