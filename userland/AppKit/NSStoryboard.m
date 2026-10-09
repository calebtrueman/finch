/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Storyboards: the .storyboardc bundles ibtool compiles, as on macOS.
 *
 * A compiled storyboard is a directory: Info.plist names the initial
 * controller (NSStoryboardDesignatedEntryPointIdentifier), the main menu's
 * nib (NSStoryboardMainMenu) and the nib holding each controller
 * (NSViewControllerIdentifiersToNibNames); a view controller's view is in a
 * nib of its own ("<controller>-view-<view>"). A controller's nib is
 * instantiated with a scene object as owner, whose sceneController outlet
 * gets the controller; objects outside the nib are placeholders
 * (NSNibExternalObjectPlaceholder) for external objects: the storyboard
 * itself, and, in a view's nib, the controller's segue templates (which
 * buttons trigger through -perform:) and anchors.
 *
 * Segues come from templates (NSStoryboardSegueTemplate and its show,
 * modal, sheet and popover kinds): -performSegueWithIdentifier:sender:
 * asks -shouldPerformSegueWithIdentifier:sender:, makes the destination
 * from the storyboard, calls -prepareForSegue:sender: and performs the
 * segue: a custom class's -perform, or the kind's presentation (popovers
 * are shown as windows; Finch has no NSPopover yet).
 *
 * This layout was learned by compiling storyboards with ibtool; the code
 * is Finch's.
 */
#import "AppKit_Finch.h"
#import "NSView_Finch.h"
#import "NSStoryboard_Finch.h"

static const void *storyboard_key = &storyboard_key;
static const void *templates_key = &templates_key;
static const void *external_key = &external_key;
static const void *identifier_key = &identifier_key;
static const void *pending_window_key = &pending_window_key;
static const void *pending_content_key = &pending_content_key;

/* The external objects of the nib being instantiated, innermost last. */
static NSMutableArray<NSDictionary *> *external_stack;

#pragma mark - Placeholders

@interface NSNibExternalObjectPlaceholder : NSObject <NSCoding>
@end

@implementation NSNibExternalObjectPlaceholder {
    NSString *_identifier;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self)
        _identifier = [[coder decodeObjectForKey:@"NSExternalObjectPlaceholderIdentifier"] copy];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_identifier forKey:@"NSExternalObjectPlaceholderIdentifier"];
}

- (void)dealloc
{
    [_identifier release];
    [super dealloc];
}

/* NSNib's instantiation asks: the external object this stands for. */
- (id)_finchNibRealObject
{
    for (NSDictionary *d in [external_stack reverseObjectEnumerator]) {
        id o = d[_identifier];
        if (o)
            return o;
    }
    NSLog(@"Finch: no external object for placeholder %@", _identifier);
    return nil;
}

@end

/* Interface Builder's user-defined runtime attributes: key paths set on an object as the nib connects. */
@interface NSIBUserDefinedRuntimeAttributesConnector : NSObject <NSCoding>
@end

@implementation NSIBUserDefinedRuntimeAttributesConnector {
    id _object;
    NSMutableArray *_values;
    NSArray *_keyPaths;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        _object = [[coder decodeObjectForKey:@"NSObject"] retain];
        _values = [[coder decodeObjectForKey:@"NSValues"] mutableCopy];
        _keyPaths = [[coder decodeObjectForKey:@"NSKeyPaths"] copy];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

- (void)dealloc
{
    [_object release];
    [_values release];
    [_keyPaths release];
    [super dealloc];
}

/* What NSIBObjectData asks of a connector. */
- (id)source { return _object; }
- (id)destination { return nil; }
- (NSString *)label { return nil; }

- (void)replaceObject:(id)old withObject:(id)new
{
    if (_object == old) {
        [_object autorelease];
        _object = [new retain];
    }
    for (NSUInteger i = 0; i < [_values count]; i++)
        if (_values[i] == old)
            _values[i] = new ?: (id)[NSNull null];
}

- (void)establishConnection
{
    for (NSUInteger i = 0; i < MIN([_values count], [_keyPaths count]); i++) {
        id v = _values[i] == [NSNull null] ? nil : _values[i];
        @try {
            [_object setValue:v forKeyPath:_keyPaths[i]];
        } @catch (NSException *e) {
            NSLog(@"Failed to set (%@) user defined inspected property on (%@): %@", _keyPaths[i], _object, [e reason]);
        }
    }
}

@end

/* The owner of a storyboard scene's nib. */
@interface _FinchStoryboardScene : NSObject
@property (retain) id sceneController;
@end

@implementation _FinchStoryboardScene
@synthesize sceneController = _sceneController;
- (void)dealloc
{
    [_sceneController release];
    [super dealloc];
}
@end

static BOOL
instantiate_nib(NSString *path, id owner, NSDictionary *external, NSArray **top)
{
    NSNib *nib = [[[NSNib alloc] initWithNibNamed:path bundle:nil] autorelease];
    if (!nib)
        return NO;
    if (!external_stack)
        external_stack = [[NSMutableArray alloc] init];
    [external_stack addObject:external ?: @{}];
    BOOL ok = NO;
    @try {
        ok = [nib instantiateWithOwner:owner topLevelObjects:top];
    } @finally {
        [external_stack removeLastObject];
    }
    return ok;
}

#pragma mark - Segue templates

@interface NSStoryboardSegueTemplate : NSObject <NSCoding>
@property (assign) id controller;
@property (assign) NSStoryboard *storyboard;
@property (assign) NSView *anchorView;
@property (readonly) NSString *identifier;
@property (readonly) NSString *destinationIdentifier;
- (NSStoryboardSegue *)_finchSegueWithDestination:(id)destination;
@end

@implementation NSStoryboardSegueTemplate {
  @protected
    NSString *_identifier, *_destination, *_segueClass, *_trigger;
}
@synthesize controller = _controller, storyboard = _storyboard, anchorView = _anchorView;

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super init];
    if (self) {
        _identifier = [[coder decodeObjectForKey:@"NSIdentifier"] copy];
        _destination = [[coder decodeObjectForKey:@"NSDestinationControllerIdentifier"] copy];
        _segueClass = [[coder decodeObjectForKey:@"NSSegueClassName"] copy];
        _trigger = [[coder decodeObjectForKey:@"NSTrigger"] copy];
        _anchorView = [coder decodeObjectForKey:@"NSAnchorView"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
}

- (void)dealloc
{
    [_identifier release];
    [_destination release];
    [_segueClass release];
    [_trigger release];
    [super dealloc];
}

- (NSString *)identifier { return _identifier; }
- (NSString *)destinationIdentifier { return _destination; }

/* A button's action (IBSegueTriggerAction): perform through the controller. */
- (IBAction)perform:(id)sender
{
    [_controller performSegueWithIdentifier:_identifier sender:sender];
}

/* The kind's presentation, from the source to the destination. */
- (void)_finchPresentFrom:(id)source to:(id)destination
{
}

- (NSStoryboardSegue *)_finchSegueWithDestination:(id)destination
{
    Class c = _segueClass ? NSClassFromString(_segueClass) : Nil;
    if (c && [c isSubclassOfClass:[NSStoryboardSegue class]])
        return [[[c alloc] initWithIdentifier:_identifier source:_controller destination:destination] autorelease];
    id source = _controller;
    return [NSStoryboardSegue segueWithIdentifier:_identifier source:source destination:destination performHandler:^{
        [self _finchPresentFrom:source to:destination];
    }];
}

@end

static NSViewController *
view_controller_of(id controller)
{
    if ([controller isKindOfClass:[NSViewController class]])
        return controller;
    if ([controller isKindOfClass:[NSWindowController class]])
        return [controller contentViewController];
    return nil;
}

static void
show(id destination, id sender)
{
    if ([destination isKindOfClass:[NSWindowController class]])
        [destination showWindow:sender];
    else if ([destination isKindOfClass:[NSViewController class]])
        [[NSWindow windowWithContentViewController:destination] makeKeyAndOrderFront:sender];
}

@interface NSStoryboardShowSegueTemplate : NSStoryboardSegueTemplate
@end
@implementation NSStoryboardShowSegueTemplate
- (void)_finchPresentFrom:(id)source to:(id)destination
{
    show(destination, source);
}
@end

@interface NSStoryboardModalSegueTemplate : NSStoryboardSegueTemplate
@end
@implementation NSStoryboardModalSegueTemplate
- (void)_finchPresentFrom:(id)source to:(id)destination
{
    if ([destination isKindOfClass:[NSWindowController class]]) {
        [NSApp runModalForWindow:[destination window]];
        return;
    }
    NSViewController *from = view_controller_of(source);
    if (from && [destination isKindOfClass:[NSViewController class]])
        [from presentViewControllerAsModalWindow:destination];
}
@end

@interface NSStoryboardSheetSegueTemplate : NSStoryboardSegueTemplate
@end
@implementation NSStoryboardSheetSegueTemplate
- (void)_finchPresentFrom:(id)source to:(id)destination
{
    NSViewController *from = view_controller_of(source);
    if (from && [destination isKindOfClass:[NSViewController class]])
        [from presentViewControllerAsSheet:destination];
    else
        show(destination, source);
}
@end

/* Popovers, as windows next to their anchor (Finch has no NSPopover yet). */
@interface NSStoryboardPopoverSegueTemplate : NSStoryboardSegueTemplate
@end
@implementation NSStoryboardPopoverSegueTemplate {
    NSInteger _behavior;
    NSRectEdge _edge;
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        _behavior = [coder decodeIntegerForKey:@"NSPopoverBehavior"];
        _edge = (NSRectEdge)[coder decodeIntegerForKey:@"NSPreferredEdge"];
    }
    return self;
}
- (void)_finchPresentFrom:(id)source to:(id)destination
{
    if (![destination isKindOfClass:[NSViewController class]]) {
        show(destination, source);
        return;
    }
    NSWindow *w = [NSWindow windowWithContentViewController:destination];
    NSView *anchor = [self anchorView];
    if ([anchor window]) {
        NSRect r = [[anchor window] convertRectToScreen:[anchor convertRect:[anchor bounds] toView:nil]];
        [w setFrameTopLeftPoint:NSMakePoint(NSMinX(r), NSMinY(r))];
    }
    [w makeKeyAndOrderFront:source];
}
@end

#pragma mark - Segues

@implementation NSStoryboardSegue {
    NSString *_identifier;
    id _source, _destination;
    void (^_handler)(void);
}

+ (instancetype)segueWithIdentifier:(NSStoryboardSegueIdentifier)identifier source:(id)source
                        destination:(id)destination performHandler:(void (^)(void))handler
{
    NSStoryboardSegue *s = [[[self alloc] initWithIdentifier:identifier source:source destination:destination] autorelease];
    s->_handler = [handler copy];
    return s;
}

- (instancetype)initWithIdentifier:(NSStoryboardSegueIdentifier)identifier source:(id)source destination:(id)destination
{
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _source = [source retain];
        _destination = [destination retain];
    }
    return self;
}

- (instancetype)init
{
    id none = nil;
    return [self initWithIdentifier:none source:none destination:none];
}

- (void)dealloc
{
    [_identifier release];
    [_source release];
    [_destination release];
    [_handler release];
    [super dealloc];
}

- (NSStoryboardSegueIdentifier)identifier { return _identifier; }
- (id)sourceController { return _source; }
- (id)destinationController { return _destination; }

- (void)perform
{
    if (_handler)
        _handler();
}

@end

static NSArray *
templates_of(id controller)
{
    return objc_getAssociatedObject(controller, templates_key);
}

static void
perform_segue(id controller, NSString *identifier, id sender)
{
    NSStoryboardSegueTemplate *t = nil;
    for (NSStoryboardSegueTemplate *x in templates_of(controller))
        if ([[x identifier] isEqualToString:identifier])
            t = x;
    if (!t)
        return;
    if (![controller shouldPerformSegueWithIdentifier:identifier sender:sender])
        return;
    NSStoryboard *sb = [t storyboard] ?: [controller storyboard];
    id destination = [sb instantiateControllerWithIdentifier:[t destinationIdentifier]];
    NSStoryboardSegue *segue = [t _finchSegueWithDestination:destination];
    [controller prepareForSegue:segue sender:sender];
    [segue perform];
}

@implementation NSViewController (NSSeguePerforming)
- (void)prepareForSegue:(NSStoryboardSegue *)segue sender:(id)sender {}
- (BOOL)shouldPerformSegueWithIdentifier:(NSStoryboardSegueIdentifier)identifier sender:(id)sender { return YES; }
- (void)performSegueWithIdentifier:(NSStoryboardSegueIdentifier)identifier sender:(id)sender
{
    perform_segue(self, identifier, sender);
}
@end

@implementation NSWindowController (NSSeguePerforming)
- (void)prepareForSegue:(NSStoryboardSegue *)segue sender:(id)sender {}
- (BOOL)shouldPerformSegueWithIdentifier:(NSStoryboardSegueIdentifier)identifier sender:(id)sender { return YES; }
- (void)performSegueWithIdentifier:(NSStoryboardSegueIdentifier)identifier sender:(id)sender
{
    perform_segue(self, identifier, sender);
}
@end

#pragma mark - Controllers from storyboards

/* -[NSViewController initWithCoder:] and -[NSWindowController initWithCoder:] call this for storyboard keys. */
void
FinchStoryboardDecodeController(id controller, NSCoder *coder)
{
    NSArray *templates = [coder decodeObjectForKey:@"NSStoryboardSegueTemplates"];
    if (templates)
        objc_setAssociatedObject(controller, templates_key, templates, OBJC_ASSOCIATION_RETAIN);
    NSDictionary *external = [coder decodeObjectForKey:@"NSExternalObjectsTableForViewLoading"];
    if (external)
        objc_setAssociatedObject(controller, external_key, external, OBJC_ASSOCIATION_RETAIN);
    NSString *identifier = [coder decodeObjectForKey:@"NSStoryboardIdentifier"] ?: [coder decodeObjectForKey:@"explicitStoryboardIdentifier"];
    if (identifier)
        objc_setAssociatedObject(controller, identifier_key, identifier, OBJC_ASSOCIATION_COPY);
    if ([controller isKindOfClass:[NSWindowController class]]) {
        id window = [coder decodeObjectForKey:@"IBWindowTemplate"];
        if (window)
            objc_setAssociatedObject(controller, pending_window_key, window, OBJC_ASSOCIATION_RETAIN);
        id content = [coder decodeObjectForKey:@"IBWindowTemplateContentViewController"];
        if (content)
            objc_setAssociatedObject(controller, pending_content_key, content, OBJC_ASSOCIATION_RETAIN);
    }
}

/* -[NSViewController loadView] for a storyboard's controller: its view's own nib, inside the storyboard. */
BOOL
FinchStoryboardLoadView(NSViewController *controller)
{
    NSStoryboard *sb = objc_getAssociatedObject(controller, storyboard_key) ?: [controller storyboard];
    NSString *name = [controller nibName];
    if (!sb || !name)
        return NO;
    NSString *path = [[sb _finchPath] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"nib"]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return NO;
    NSMutableDictionary *external = [NSMutableDictionary dictionaryWithDictionary:objc_getAssociatedObject(controller, external_key) ?: @{}];
    external[@"NSStoryboardPlaceholder"] = sb;
    NSArray *top = nil;
    if (!instantiate_nib(path, controller, external, &top))
        [NSException raise:NSInternalInconsistencyException
                    format:@"-[%@ loadView] loaded the \"%@\" nib but no view was set.", NSStringFromClass([controller class]), name];
    return YES;
}

/* After a controller's nib: storyboard links, and a window controller's window and content. */
static void
finish_controller(id controller, NSStoryboard *sb)
{
    if (!controller)
        return;
    objc_setAssociatedObject(controller, storyboard_key, sb, OBJC_ASSOCIATION_RETAIN);
    for (NSStoryboardSegueTemplate *t in templates_of(controller)) {
        if (![t controller])
            [t setController:controller];
        if (![t storyboard])
            [t setStoryboard:sb];
    }
    if (![controller isKindOfClass:[NSWindowController class]])
        return;
    NSWindowController *wc = controller;
    NSWindow *w = objc_getAssociatedObject(wc, pending_window_key);
    NSViewController *content = objc_getAssociatedObject(wc, pending_content_key);
    if (!w)
        return;
    [[w retain] autorelease];
    [[content retain] autorelease];
    objc_setAssociatedObject(wc, pending_window_key, nil, OBJC_ASSOCIATION_RETAIN);
    objc_setAssociatedObject(wc, pending_content_key, nil, OBJC_ASSOCIATION_RETAIN);
    [wc windowWillLoad];
    [wc setWindow:w];
    if (content) {
        finish_controller(content, sb);
        if ([w contentViewController] != content)  /* the nib's runtime attributes usually set it */
            [wc setContentViewController:content];
    }
    [wc windowDidLoad];
}

#pragma mark - NSStoryboard

@implementation NSStoryboard {
    NSString *_name, *_path;
    NSBundle *_bundle;
    NSDictionary *_info;
}

static NSStoryboard *main_storyboard;

+ (NSStoryboard *)mainStoryboard
{
    if (!main_storyboard) {
        NSString *name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSMainStoryboardFile"];
        if ([name length])
            main_storyboard = [[self storyboardWithName:name bundle:[NSBundle mainBundle]] retain];
    }
    return main_storyboard;
}

+ (instancetype)storyboardWithName:(NSStoryboardName)name bundle:(NSBundle *)bundle
{
    if (!bundle)
        bundle = [NSBundle mainBundle];
    NSString *path = [bundle pathForResource:name ofType:@"storyboardc"];
    NSDictionary *info = path ? [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]] : nil;
    if (!info)
        [NSException raise:NSInvalidArgumentException
                    format:@"Could not find a storyboard named '%@' in bundle %@", name, bundle];
    NSStoryboard *sb = [[[self alloc] init] autorelease];
    sb->_name = [name copy];
    sb->_path = [path copy];
    sb->_bundle = [bundle retain];
    sb->_info = [info retain];
    return sb;
}

- (void)dealloc
{
    [_name release];
    [_path release];
    [_bundle release];
    [_info release];
    [super dealloc];
}

- (NSString *)_finchPath { return _path; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<NSStoryboard:%p path='%@', initialController='%@'>", self, _path,
                                      _info[@"NSStoryboardDesignatedEntryPointIdentifier"]];
}

- (id)instantiateControllerWithIdentifier:(NSStoryboardSceneIdentifier)identifier
{
    NSString *nibName = _info[@"NSViewControllerIdentifiersToNibNames"][identifier];
    if (!nibName)
        [NSException raise:NSInvalidArgumentException
                    format:@"Storyboard (%@) doesn't contain a controller with identifier '%@'", self, identifier];
    _FinchStoryboardScene *scene = [[[_FinchStoryboardScene alloc] init] autorelease];
    NSArray *top = nil;
    NSString *path = [_path stringByAppendingPathComponent:[nibName stringByAppendingPathExtension:@"nib"]];
    if (!instantiate_nib(path, scene, @{@"NSStoryboardPlaceholder" : self}, &top))
        [NSException raise:NSInternalInconsistencyException format:@"Could not load the nib for '%@' in %@", identifier, self];
    id controller = [[[scene sceneController] retain] autorelease];
    finish_controller(controller, self);
    return controller;
}

- (id)instantiateControllerWithIdentifier:(NSStoryboardSceneIdentifier)identifier creator:(NS_NOESCAPE NSStoryboardControllerCreator)block
{
    return [self instantiateControllerWithIdentifier:identifier];
}

- (id)instantiateInitialController
{
    NSString *entry = _info[@"NSStoryboardDesignatedEntryPointIdentifier"];
    return entry ? [self instantiateControllerWithIdentifier:entry] : nil;
}

- (id)instantiateInitialControllerWithCreator:(NS_NOESCAPE NSStoryboardControllerCreator)block
{
    return [self instantiateInitialController];
}

/* The main menu's nib, owned by the application (it holds the app scene: the menu, the delegate). */
- (void)_finchLoadMainMenu
{
    NSString *menu = _info[@"NSStoryboardMainMenu"];
    if (!menu)
        return;
    NSString *path = [_path stringByAppendingPathComponent:[menu stringByAppendingPathExtension:@"nib"]];
    NSArray *top = nil;
    if (instantiate_nib(path, NSApp, @{@"NSStoryboardPlaceholder" : self}, &top))
        [top makeObjectsPerformSelector:@selector(retain)];  /* the application keeps its scene */
}

@end

/* NSApplicationMain with NSMainStoryboardFile: the main menu, then the initial controller, shown. */
void
FinchStoryboardLaunch(NSApplication *app, NSBundle *bundle)
{
    NSStoryboard *sb = [NSStoryboard mainStoryboard];
    if (!sb)
        return;
    [sb _finchLoadMainMenu];
    id initial = [sb instantiateInitialController];
    if ([initial isKindOfClass:[NSWindowController class]])
        [[initial retain] showWindow:app];
    else if ([initial isKindOfClass:[NSViewController class]])
        [[[NSWindow windowWithContentViewController:[initial retain]] retain] makeKeyAndOrderFront:app];
}
