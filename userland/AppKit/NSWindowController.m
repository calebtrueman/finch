/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSWindowController: owns a window, loading it from a nib on first use,
 * and links it to a document (its title, closing). It is the window's next
 * responder, as on macOS.
 */
#import "NSView_Finch.h"
#import "NSStoryboard_Finch.h"

@implementation NSWindowController {
    NSWindow *_window;
    NSString *_nibName, *_nibPath;
    id _owner;  /* not retained */
    id _document;  /* not retained: the document owns its controllers */
    NSWindowFrameAutosaveName _autosaveName;
    NSViewController *_contentViewController;
    NSStoryboard *_storyboard;
    struct {
        unsigned cascade : 1;
        unsigned closesDocument : 1;
        unsigned loading : 1;
    } _c;
}

- (instancetype)initWithWindow:(NSWindow *)window
{
    self = [super init];
    if (self) {
        _c.cascade = YES;
        [self setWindow:window];
    }
    return self;
}

- (instancetype)init
{
    return [self initWithWindow:nil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        _c.cascade = YES;
        FinchStoryboardDecodeController(self, coder);  /* a storyboard's window controller */
    }
    return self;
}

- (instancetype)initWithWindowNibName:(NSNibName)name
{
    return [self initWithWindowNibName:name owner:self];
}

- (instancetype)initWithWindowNibName:(NSNibName)name owner:(id)owner
{
    if (!owner)
        [NSException raise:NSInternalInconsistencyException format:@"Invalid parameter not satisfying: owner"];
    self = [self initWithWindow:nil];
    if (self) {
        _nibName = [name copy];
        _owner = owner;
    }
    return self;
}

- (instancetype)initWithWindowNibPath:(NSString *)path owner:(id)owner
{
    if (!owner)
        [NSException raise:NSInternalInconsistencyException format:@"Invalid parameter not satisfying: owner"];
    self = [self initWithWindow:nil];
    if (self) {
        _nibPath = [path copy];
        _nibName = [[[path lastPathComponent] stringByDeletingPathExtension] copy];
        _owner = owner;
    }
    return self;
}

- (void)dealloc
{
    [_window setWindowController:nil];
    [_window release];
    [_nibName release];
    [_nibPath release];
    [_autosaveName release];
    [_contentViewController release];
    [super dealloc];
}

- (NSNibName)windowNibName { return _nibName; }
/* The nib's path, from -windowNibName (which subclasses override, as Apple's documents),
   in the owner's bundle or else the main bundle. */
- (NSString *)windowNibPath
{
    if (_nibPath)
        return _nibPath;
    NSString *name = [self windowNibName];
    if (!name)
        return nil;
    NSBundle *b = [NSBundle bundleForClass:[_owner ?: self class]];
    return [b pathForResource:name ofType:@"nib"] ?: [[NSBundle mainBundle] pathForResource:name ofType:@"nib"];
}
- (id)owner { return _owner; }
- (NSWindowFrameAutosaveName)windowFrameAutosaveName { return _autosaveName ?: @""; }
- (void)setWindowFrameAutosaveName:(NSWindowFrameAutosaveName)name
{
    [_autosaveName autorelease];
    _autosaveName = [name copy];
    if (_window)
        [_window setFrameAutosaveName:name];
}
- (BOOL)shouldCascadeWindows { return _c.cascade; }
- (void)setShouldCascadeWindows:(BOOL)flag { _c.cascade = flag; }
- (BOOL)shouldCloseDocument { return _c.closesDocument; }
- (void)setShouldCloseDocument:(BOOL)flag { _c.closesDocument = flag; }
- (NSStoryboard *)storyboard { return _storyboard; }

/* As Apple's: with no nib to load, the window counts as loaded. */
- (BOOL)isWindowLoaded { return _window != nil || (![self windowNibName] && !_nibPath); }

- (NSWindow *)window
{
    if (!_window && !_c.loading && ([self windowNibName] || [self windowNibPath])) {
        _c.loading = YES;
        [self windowWillLoad];
        if ([_document respondsToSelector:@selector(windowControllerWillLoadNib:)])
            [_document windowControllerWillLoadNib:self];
        [self loadWindow];
        if (_window) {
            if (_c.cascade) {
                static NSPoint cascade;
                cascade = [_window cascadeTopLeftFromPoint:cascade];
            }
            if ([_autosaveName length]) {
                [_window setFrameUsingName:_autosaveName];
                [_window setFrameAutosaveName:_autosaveName];
            }
            [self synchronizeWindowTitleWithDocumentName];
        }
        [self windowDidLoad];
        if ([_document respondsToSelector:@selector(windowControllerDidLoadNib:)])
            [_document windowControllerDidLoadNib:self];
        _c.loading = NO;
    }
    return _window;
}

- (void)setWindow:(NSWindow *)window
{
    if (window == _window)
        return;
    if ([_window windowController] == self)
        [_window setWindowController:nil];
    [_window release];
    _window = [window retain];
    [_window setWindowController:self];
}

- (void)loadWindow
{
    if (_window)
        return;
    NSString *path = [self windowNibPath];
    if (path && ![path isAbsolutePath])
        path = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:path];
    NSBundle *bundle = [NSBundle bundleForClass:[_owner ?: self class]];
    /* a compiled nib is a file or a directory: NSNib reads either */
    NSNib *nib = path ? [[[NSNib alloc] initWithNibNamed:path bundle:bundle] autorelease] : nil;
    if (!nib || ![nib instantiateWithOwner:_owner ?: self topLevelObjects:NULL]) {
        NSLog(@"%@: unable to load nib file: %@", self, [self windowNibName]);
        return;
    }
    if (!_window)
        NSLog(@"%@: could not find window in nib %@ (is the window outlet connected?)", self, [self windowNibName]);
}

- (void)loadWindowIfNeeded
{
    [self window];
}

- (void)windowWillLoad {}
- (void)windowDidLoad {}

- (void)showWindow:(id)sender
{
    NSWindow *w = [self window];
    if ([w isKindOfClass:[NSPanel class]] && [(NSPanel *)w becomesKeyOnlyIfNeeded])
        [w orderFront:sender];
    else
        [w makeKeyAndOrderFront:sender];
}

- (void)close
{
    [_window close];
}

- (IBAction)dismissController:(id)sender
{
    [self close];
}

- (NSViewController *)contentViewController
{
    return _contentViewController ?: [[self window] contentViewController];
}

- (void)setContentViewController:(NSViewController *)controller
{
    [_contentViewController autorelease];
    _contentViewController = [controller retain];
    [[self window] setContentViewController:controller];
}

#pragma mark - Documents

- (id)document { return _document; }

- (void)setDocument:(id)document
{
    _document = document;
    [self synchronizeWindowTitleWithDocumentName];
}

- (void)setDocumentEdited:(BOOL)flag
{
    [_window setDocumentEdited:flag];
}

- (NSString *)windowTitleForDocumentDisplayName:(NSString *)displayName
{
    return displayName;
}

- (void)synchronizeWindowTitleWithDocumentName
{
    if (!_document || !_window)
        return;
    NSString *title = [self windowTitleForDocumentDisplayName:[_document displayName]];
    NSURL *url = [_document fileURL];
    if (url && [url isFileURL])
        [_window setRepresentedFilename:[url path]];
    [_window setTitle:title ?: @""];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
}

@end

#pragma mark - NSViewController

@implementation NSViewController {
    NSView *_view;
    NSString *_nibName;
    NSBundle *_nibBundle;
    id _representedObject;
    NSString *_title;
    NSMutableArray<NSViewController *> *_children;
    NSViewController *_parent;  /* not retained */
    NSSize _preferredContentSize;
    NSStoryboard *_storyboard;
    BOOL _loading;
}

static const void *view_controller_key = &view_controller_key;

/* The view controller whose view this is, if any. */
FINCH_PRIVATE NSViewController *
FinchViewControllerOf(NSView *view)
{
    return objc_getAssociatedObject(view, view_controller_key);
}

- (instancetype)initWithNibName:(NSNibName)name bundle:(NSBundle *)bundle
{
    self = [super init];
    if (self) {
        _nibName = [name copy];
        _nibBundle = [bundle retain];
    }
    return self;
}

- (instancetype)init
{
    return [self initWithNibName:nil bundle:nil];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        _nibName = [[coder decodeObjectForKey:@"NSNibName"] copy];
        _nibBundle = [[coder decodeObjectForKey:@"NSNibBundleIdentifier"] isKindOfClass:[NSString class]]
                         ? [[NSBundle bundleWithIdentifier:[coder decodeObjectForKey:@"NSNibBundleIdentifier"]] retain]
                         : nil;
        _title = [[coder decodeObjectForKey:@"NSTitle"] copy];
        NSView *v = [coder decodeObjectForKey:@"NSView"];
        if (v)
            [self setView:v];
        FinchStoryboardDecodeController(self, coder);  /* a storyboard's view controller */
    }
    return self;
}

- (void)dealloc
{
    if (_view)
        objc_setAssociatedObject(_view, view_controller_key, nil, OBJC_ASSOCIATION_ASSIGN);
    [_view release];
    [_nibName release];
    [_nibBundle release];
    [_representedObject release];
    [_title release];
    [_children release];
    [super dealloc];
}

/* As Apple's: with no nib name, a nib named after the class, if the bundle has one. */
- (NSNibName)nibName
{
    if (_nibName)
        return _nibName;
    NSString *name = NSStringFromClass([self class]);
    NSRange dot = [name rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location != NSNotFound)
        name = [name substringFromIndex:NSMaxRange(dot)];  /* Swift's Module.Class */
    NSBundle *b = [self nibBundle] ?: [NSBundle mainBundle];
    return [b pathForResource:name ofType:@"nib"] ? name : nil;
}

- (NSBundle *)nibBundle
{
    return _nibBundle;
}

- (NSStoryboard *)storyboard { return _storyboard; }
- (BOOL)isViewLoaded { return _view != nil; }
- (NSView *)viewIfLoaded { return _view; }

- (NSView *)view
{
    if (!_view && !_loading) {
        _loading = YES;
        [self loadView];
        if (_view)
            [self viewDidLoad];
        _loading = NO;
    }
    return _view;
}

- (void)setView:(NSView *)view
{
    if (view == _view)
        return;
    if (_view)
        objc_setAssociatedObject(_view, view_controller_key, nil, OBJC_ASSOCIATION_ASSIGN);
    [_view release];
    _view = [view retain];
    if (view) {
        objc_setAssociatedObject(view, view_controller_key, self, OBJC_ASSOCIATION_ASSIGN);
        /* the controller goes between the view and what was next */
        NSResponder *next = [view nextResponder];
        if (next != self) {
            [self setNextResponder:next];
            [view setNextResponder:self];
        }
    }
}

- (void)loadView
{
    if (FinchStoryboardLoadView(self))
        return;
    NSString *name = [self nibName];
    if (!name) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"-[%@ %@] was unable to load the nib named \"%@\"", NSStringFromClass([self class]),
                           NSStringFromSelector(_cmd), NSStringFromClass([self class])];
        return;
    }
    NSBundle *b = [self nibBundle] ?: [NSBundle mainBundle];
    NSNib *nib = [[[NSNib alloc] initWithNibNamed:name bundle:b] autorelease];
    if (![nib instantiateWithOwner:self topLevelObjects:NULL])
        [NSException raise:NSInternalInconsistencyException
                    format:@"-[%@ %@] loaded the \"%@\" nib but no view was set.", NSStringFromClass([self class]),
                           NSStringFromSelector(_cmd), name];
}

- (void)loadViewIfNeeded
{
    [self view];
}

- (void)viewDidLoad {}
- (void)viewWillAppear {}
- (void)viewDidAppear {}
- (void)viewWillDisappear {}
- (void)viewDidDisappear {}
- (void)updateViewConstraints {}
- (void)viewWillLayout {}
- (void)viewDidLayout {}
- (BOOL)commitEditing { return YES; }
- (void)discardEditing {}

- (id)representedObject { return _representedObject; }
- (void)setRepresentedObject:(id)object { [_representedObject autorelease]; _representedObject = [object retain]; }
- (NSString *)title { return _title; }
- (void)setTitle:(NSString *)title { [_title autorelease]; _title = [title copy]; }
- (NSSize)preferredContentSize { return _preferredContentSize; }
- (void)setPreferredContentSize:(NSSize)size { _preferredContentSize = size; }
- (NSSize)preferredMinimumSize { return [self isViewLoaded] ? [_view fittingSize] : NSZeroSize; }
- (NSSize)preferredMaximumSize { return NSMakeSize(FLT_MAX, FLT_MAX); }

- (NSArray<NSViewController *> *)childViewControllers { return _children ? [[_children copy] autorelease] : @[]; }
- (void)setChildViewControllers:(NSArray<NSViewController *> *)children
{
    for (NSViewController *c in [self childViewControllers])
        [c removeFromParentViewController];
    for (NSViewController *c in children)
        [self addChildViewController:c];
}
- (NSViewController *)parentViewController { return _parent; }

- (void)addChildViewController:(NSViewController *)child
{
    [self insertChildViewController:child atIndex:[_children count]];
}

- (void)insertChildViewController:(NSViewController *)child atIndex:(NSInteger)index
{
    [child retain];
    [child removeFromParentViewController];
    if (!_children)
        _children = [[NSMutableArray alloc] init];
    [_children insertObject:child atIndex:(NSUInteger)index];
    child->_parent = self;
    [child release];
}

- (void)removeChildViewControllerAtIndex:(NSInteger)index
{
    NSViewController *c = _children[(NSUInteger)index];
    c->_parent = nil;
    [_children removeObjectAtIndex:(NSUInteger)index];
}

- (void)removeFromParentViewController
{
    if (!_parent)
        return;
    NSUInteger i = [_parent->_children indexOfObjectIdenticalTo:self];
    if (i != NSNotFound)
        [_parent removeChildViewControllerAtIndex:(NSInteger)i];
}

- (void)presentViewControllerAsModalWindow:(NSViewController *)controller
{
    NSWindow *w = [NSWindow windowWithContentViewController:controller];
    [w makeKeyAndOrderFront:self];
}

- (void)presentViewControllerAsSheet:(NSViewController *)controller
{
    [self presentViewControllerAsModalWindow:controller];
}

- (void)dismissViewController:(NSViewController *)controller
{
    extern BOOL FinchDismissPopoverController(NSViewController *);
    if (FinchDismissPopoverController(controller)) return;
    [[[controller view] window] close];
}

- (IBAction)dismissController:(id)sender
{
    [self dismissViewController:self];
}

- (void)presentViewController:(NSViewController *)controller relativeToRect:(NSRect)rect ofView:(NSView *)view
               preferredEdge:(NSRectEdge)edge behavior:(NSPopoverBehavior)behavior
{
    NSPopover *popover = [[[NSPopover alloc] init] autorelease];
    [popover setContentViewController:controller];
    [popover setBehavior:behavior];
    [popover showRelativeToRect:rect ofView:view preferredEdge:edge];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [super encodeWithCoder:coder];
}

@end
