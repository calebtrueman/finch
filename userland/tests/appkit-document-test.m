/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-document-test: the controllers and the document
 * architecture: NSWindowController and NSViewController loading their nibs
 * (doc-test.xib, vc-test.xib), the responder chain they join, and
 * NSDocument/NSDocumentController (untitled names, change counts, undo,
 * reading and writing, closing). Prints everything; run it against Apple's
 * AppKit and Finch's (DYLD_FRAMEWORK_PATH) and diff.
 *
 *   finch-appkit-document-test [directory holding doc-test.nib and vc-test.nib]
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSMutableArray<NSString *> *log_;

static void
flush(const char *label)
{
    printf("%s: %s\n", label, [log_ componentsJoinedByString:@"; "].UTF8String);
    [log_ removeAllObjects];
}

@interface WC : NSWindowController
@property (strong) NSView *marker;
- (instancetype)initWithPath:(NSString *)path;
@end
@implementation WC
- (instancetype)initWithPath:(NSString *)path
{
    return [super initWithWindowNibPath:path owner:self];
}
- (void)windowWillLoad
{
    [log_ addObject:@"windowWillLoad"];
}
- (void)windowDidLoad
{
    [log_ addObject:[NSString stringWithFormat:@"windowDidLoad window %d marker %d", self.window != nil,
                                               self.marker != nil]];
}
- (void)awakeFromNib
{
    [log_ addObject:@"WC awakeFromNib"];
}
- (NSString *)windowTitleForDocumentDisplayName:(NSString *)name
{
    return [name stringByAppendingString:@" (doc)"];
}
@end

/* A controller naming its nib by overriding -windowNibName, found in the main bundle
   (the tool's folder, where doc-test.nib is) */
@interface NamedWC : NSWindowController
@property (strong) NSView *marker;
@end
@implementation NamedWC
- (NSNibName)windowNibName { return @"doc-test"; }
@end

@interface VC : NSViewController
@end
@implementation VC
- (void)loadView
{
    [log_ addObject:@"loadView"];
    [super loadView];
}
- (void)viewDidLoad
{
    [log_ addObject:[NSString stringWithFormat:@"viewDidLoad frame %@", NSStringFromRect(self.view.frame)]];
}
@end

@interface Doc : NSDocument
@property (copy) NSString *text;
@property (copy) NSString *nibDir;
@end
@implementation Doc
- (NSData *)dataOfType:(NSString *)type error:(NSError **)e
{
    [log_ addObject:[NSString stringWithFormat:@"dataOfType %@", type]];
    return [self.text dataUsingEncoding:NSUTF8StringEncoding];
}
- (BOOL)readFromData:(NSData *)d ofType:(NSString *)type error:(NSError **)e
{
    [log_ addObject:[NSString stringWithFormat:@"readFromData %@ %lu", type, (unsigned long)d.length]];
    self.text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return YES;
}
- (void)makeWindowControllers
{
    WC *wc = [[WC alloc] initWithPath:[self.nibDir stringByAppendingPathComponent:@"doc-test.nib"]];
    [self addWindowController:wc];
}
@end

static void
controllers(NSString *dir)
{
    printf("== window controller\n");
    WC *wc = [[WC alloc] initWithPath:[dir stringByAppendingPathComponent:@"doc-test.nib"]];
    @try {
        (void)[[NSWindowController alloc] initWithWindowNibPath:@"x" owner:(id _Nonnull)nil];
        printf("nil owner accepted\n");
    } @catch (NSException *e) {
        printf("nil owner: %s %s\n", e.name.UTF8String, e.reason.UTF8String);
    }
    printf("loaded before %d nibName %s owner is wc %d cascade %d closesDoc %d\n", wc.isWindowLoaded,
           wc.windowNibName.UTF8String, wc.owner == wc, wc.shouldCascadeWindows, wc.shouldCloseDocument);
    NSWindow *w = wc.window;
    flush("load");
    printf("loaded %d title %s controller %d next responder is wc %d\n", wc.isWindowLoaded, w.title.UTF8String,
           w.windowController == wc, w.nextResponder == wc);
    NamedWC *named = [[NamedWC alloc] initWithWindow:nil];
    printf("named: loaded before %d, window %d, path ends %s\n", named.isWindowLoaded, named.window != nil,
           named.windowNibPath.lastPathComponent.UTF8String);
    NSWindowController *plain = [[NSWindowController alloc] initWithWindow:nil];
    printf("plain window %p loaded %d\n", plain.window, plain.isWindowLoaded);
    NSWindow *w2 = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10) styleMask:0
                                                 backing:NSBackingStoreBuffered defer:YES];
    plain.window = w2;
    printf("set window: controller %d next %d\n", w2.windowController == plain, w2.nextResponder == plain);
    [w2 setReleasedWhenClosed:NO];

    printf("== view controller\n");
    VC *vc = [[VC alloc] initWithNibName:@"vc-test" bundle:[NSBundle bundleWithPath:dir]];
    printf("nibName %s loaded %d viewIfLoaded %p\n", vc.nibName.UTF8String, vc.isViewLoaded, vc.viewIfLoaded);
    NSView *v = vc.view;
    flush("load");
    printf("loaded %d view %s next responder is vc %d\n", vc.isViewLoaded, NSStringFromRect(v.frame).UTF8String,
           v.nextResponder == vc);
    NSView *host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 500)];
    [host addSubview:v];
    printf("in a superview: view next is vc %d, vc next is host %d\n", v.nextResponder == vc, vc.nextResponder == host);
    VC *child = [[VC alloc] initWithNibName:nil bundle:nil];
    [vc addChildViewController:child];
    printf("children %lu parent %d\n", (unsigned long)vc.childViewControllers.count, child.parentViewController == vc);
    [child removeFromParentViewController];
    printf("after remove %lu\n", (unsigned long)vc.childViewControllers.count);
    vc.title = @"Titled";
    vc.representedObject = @42;
    printf("title %s represented %s\n", vc.title.UTF8String, [vc.representedObject description].UTF8String);
}

static void
documents(NSString *dir)
{
    printf("== documents\n");
    NSDocumentController *dc = [NSDocumentController sharedDocumentController];
    printf("dc %s classes %lu default %s\n", class_getName([dc class]), (unsigned long)dc.documentClassNames.count,
           dc.defaultType.UTF8String);
    NSError *err = nil;
    Doc *a = [[Doc alloc] initWithType:@"public.plain-text" error:&err], *b = [Doc new];
    printf("a type %s name '%s' b name '%s' edited %d url %s\n", a.fileType.UTF8String, a.displayName.UTF8String,
           b.displayName.UTF8String, a.isDocumentEdited, a.fileURL.description.UTF8String);
    [dc addDocument:a];
    [dc addDocument:b];
    Doc *c = [Doc new];
    [dc addDocument:c];
    printf("c '%s' docs %lu\n", c.displayName.UTF8String, (unsigned long)dc.documents.count);
    [a updateChangeCount:NSChangeDone];
    printf("done: edited %d\n", a.isDocumentEdited);
    [a updateChangeCount:NSChangeUndone];
    printf("undone: edited %d\n", a.isDocumentEdited);
    [a updateChangeCount:NSChangeDone];
    [a updateChangeCount:NSChangeDone];
    [a updateChangeCount:NSChangeCleared];
    printf("cleared: edited %d\n", a.isDocumentEdited);
    printf("undo %d hasUndo %d autosaves %d nib %s\n", a.undoManager != nil, a.hasUndoManager, [Doc autosavesInPlace],
           a.windowNibName.UTF8String);
    NSUndoManager *u = a.undoManager;
    u.groupsByEvent = NO;
    [u beginUndoGrouping];
    [u registerUndoWithTarget:a selector:@selector(setText:) object:@"old"];
    printf("registered, group open: edited %d\n", a.isDocumentEdited);
    [u endUndoGrouping];
    printf("group closed: edited %d\n", a.isDocumentEdited);
    [u undo];
    printf("undone: edited %d text %s\n", a.isDocumentEdited, a.text.UTF8String);
    [u redo];
    printf("redone: edited %d\n", a.isDocumentEdited);
    a.text = @"hello";
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-doc-test.txt"];
    NSURL *url = [NSURL fileURLWithPath:path];
    printf("write %d\n", [a writeToURL:url ofType:@"public.plain-text" error:&err]);
    flush("log");
    Doc *r = [[Doc alloc] initWithContentsOfURL:url ofType:@"public.plain-text" error:&err];
    flush("log");
    printf("read '%s' name '%s' url %s type %s edited %d date %d\n", r.text.UTF8String, r.displayName.UTF8String,
           r.fileURL.lastPathComponent.UTF8String, r.fileType.UTF8String, r.isDocumentEdited,
           r.fileModificationDate != nil);
    printf("type for url %s\n", [dc typeForContentsOfURL:url error:&err].UTF8String);
    [dc removeDocument:b];
    Doc *d = [Doc new];
    [dc addDocument:d];
    printf("after removing b: docs %lu new '%s'\n", (unsigned long)dc.documents.count, d.displayName.UTF8String);
    printf("document for url %d, current %p\n", [dc documentForURL:url] == nil, dc.currentDocument);
    /* windows */
    d.nibDir = dir;
    [d makeWindowControllers];
    WC *wc = (WC *)d.windowControllers.firstObject;
    NSWindow *w = wc.window;
    flush("doc window load");
    printf("controllers %lu wc doc %d title '%s' documentForWindow %d\n", (unsigned long)d.windowControllers.count,
           wc.document == d, w.title.UTF8String, [dc documentForWindow:w] == d);
    [d updateChangeCount:NSChangeDone];
    printf("window edited %d\n", w.isDocumentEdited);
    d.fileURL = url;
    printf("with url: name '%s' title '%s' represented %s\n", d.displayName.UTF8String, w.title.UTF8String,
           w.representedFilename.lastPathComponent.UTF8String);
    [d close];
    printf("closed: docs %lu controllers %lu\n", (unsigned long)dc.documents.count,
           (unsigned long)d.windowControllers.count);
    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", class_getImageName([NSDocument class]));
        [NSApplication sharedApplication];
        log_ = [NSMutableArray array];
        NSString *dir = argc > 1 ? @(argv[1]) : @"/usr/local/share/finch";
        controllers(dir);
        documents(dir);
    }
    return 0;
}
