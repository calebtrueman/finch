/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import "AppKit_Finch.h"

@implementation NSPageController {
    __weak id<NSPageControllerDelegate> _delegate;
    NSArray *_objects;
    NSMutableDictionary *_controllers;
    NSViewController *_selected;
    NSInteger _index;
    NSPageControllerTransitionStyle _style;
}
- (instancetype)initWithNibName:(NSString *)name bundle:(NSBundle *)bundle
{
    self = [super initWithNibName:name bundle:bundle];
    if (self) {
        _objects = [@[] copy];
        _controllers = [NSMutableDictionary new];
    }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)c
{
    self = [super initWithCoder:c];
    if (self) {
        _objects = [[c decodeObjectForKey:@"NSArrangedObjects"] copy] ?: [@[] copy];
        _controllers = [NSMutableDictionary new];
        _style = [c decodeIntegerForKey:@"NSTransitionStyle"];
        _index = [c decodeIntegerForKey:@"NSSelectedIndex"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c
{
    [super encodeWithCoder:c];
    [c encodeObject:_objects forKey:@"NSArrangedObjects"];
    [c encodeInteger:_style forKey:@"NSTransitionStyle"];
    [c encodeInteger:_index forKey:@"NSSelectedIndex"];
}
- (void)dealloc
{
    [_objects release];
    [_controllers release];
    [_selected release];
    [super dealloc];
}
- (id<NSPageControllerDelegate>)delegate
{
    return _delegate;
}
- (void)setDelegate:(id<NSPageControllerDelegate>)v
{
    _delegate = v;
    if ([self isViewLoaded])
        [self _finchSelectPage:NO];
}
- (NSPageControllerTransitionStyle)transitionStyle
{
    return _style;
}
- (void)setTransitionStyle:(NSPageControllerTransitionStyle)v
{
    _style = v;
}
- (NSArray *)arrangedObjects
{
    return _objects;
}
- (void)setArrangedObjects:(NSArray *)v
{
    NSArray *copy = [v copy] ?: [@[] copy];
    [_objects release];
    _objects = copy;
    if (_index >= (NSInteger)[_objects count])
        _index = MAX(0, (NSInteger)[_objects count] - 1);
    if ([self isViewLoaded])
        [self _finchSelectPage:NO];
}
- (NSInteger)selectedIndex
{
    return _index;
}
- (void)setSelectedIndex:(NSInteger)v
{
    if (v < 0 || v >= (NSInteger)[_objects count])
        [NSException raise:NSInternalInconsistencyException format:@"The selected page must be in arrangedObjects."];
    if (_index == v && _selected)
        return;
    _index = v;
    if ([self isViewLoaded])
        [self _finchSelectPage:YES];
}
- (NSViewController *)selectedViewController
{
    return _selected;
}
- (void)loadView
{
    if ([self nibName])
        [super loadView];
    else
        [self setView:[[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240)] autorelease]];
}
- (void)viewDidLoad
{
    [super viewDidLoad];
    [self _finchSelectPage:NO];
}
- (void)_finchSelectPage:(BOOL)notify
{
    if (!_controllers)
        _controllers = [NSMutableDictionary new];
    id object = _index >= 0 && _index < (NSInteger)[_objects count] ? _objects[_index] : nil;
    NSViewController *next = nil;
    if (object && [_delegate respondsToSelector:@selector(pageController:identifierForObject:)] &&
        [_delegate respondsToSelector:@selector(pageController:viewControllerForIdentifier:)]) {
        NSString *key = [_delegate pageController:self identifierForObject:object];
        next = key ? _controllers[key] : nil;
        if (!next) {
            next = [_delegate pageController:self viewControllerForIdentifier:key];
            if (next && key)
                _controllers[key] = next;
        }
    }
    BOOL changed = next != _selected;
    if (changed) {
        [_selected viewWillDisappear];
        [[_selected view] removeFromSuperview];
        [_selected viewDidDisappear];
        [_selected removeFromParentViewController];
        [_selected release];
        _selected = [next retain];
        if (next)
            [self addChildViewController:next];
    }
    if (next) {
        [next setRepresentedObject:object];
        if ([_delegate respondsToSelector:@selector(pageController:prepareViewController:withObject:)])
            [_delegate pageController:self prepareViewController:next withObject:object];
        NSRect frame = [_delegate respondsToSelector:@selector(pageController:frameForObject:)]
                           ? [_delegate pageController:self frameForObject:object]
                           : [[self view] bounds];
        [[next view] setFrame:frame];
        [[next view] setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        BOOL attaching = [[next view] superview] != [self view];
        if (attaching)
            [next viewWillAppear];
        if (attaching)
            [[self view] addSubview:[next view]];
        if (attaching)
            [next viewDidAppear];
    }
    if (notify && object && [_delegate respondsToSelector:@selector(pageController:didTransitionToObject:)])
        [_delegate pageController:self didTransitionToObject:object];
}
- (void)navigateBack:(id)sender
{
    if (_index > 0)
        [self setSelectedIndex:_index - 1];
}
- (void)navigateForward:(id)sender
{
    if (_index + 1 < (NSInteger)[_objects count])
        [self setSelectedIndex:_index + 1];
}
- (void)takeSelectedIndexFrom:(id)sender
{
    [self setSelectedIndex:[sender integerValue]];
}
- (void)navigateForwardToObject:(id)object
{
    if (!object)
        return;
    NSMutableArray *a = [NSMutableArray
        arrayWithArray:[_objects subarrayWithRange:NSMakeRange(0, MIN([_objects count], (NSUInteger)_index + 1))]];
    [a addObject:object];
    [self setArrangedObjects:a];
    [self setSelectedIndex:[a count] - 1];
}
- (void)completeTransition
{
}
@end
