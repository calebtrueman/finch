/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The document architecture: NSDocument (a file's contents, its windows,
 * reading and writing, the change count and undo) and NSDocumentController
 * (the app's documents and document types, from Info.plist's
 * CFBundleDocumentTypes, as on macOS).
 *
 * Open and save panels come with NSOpenPanel/NSSavePanel; until then the
 * actions that need one log and do nothing.
 */
#import "NSView_Finch.h"

#pragma mark - Types

/* A file's type: the app's declared types first, then the common ones by extension. */
static NSString *
uti_for_extension(NSString *ext)
{
    ext = [ext lowercaseString];
    static NSDictionary *common;
    if (!common)
        common = [@{
            @"txt" : @"public.plain-text", @"text" : @"public.plain-text", @"rtf" : @"public.rtf",
            @"rtfd" : @"com.apple.rtfd", @"html" : @"public.html", @"htm" : @"public.html",
            @"webarchive" : @"com.apple.webarchive", @"png" : @"public.png", @"jpg" : @"public.jpeg",
            @"jpeg" : @"public.jpeg", @"pdf" : @"com.adobe.pdf", @"json" : @"public.json", @"xml" : @"public.xml",
            @"c" : @"public.c-source", @"m" : @"public.objective-c-source", @"swift" : @"public.swift-source",
            @"md" : @"net.daringfireball.markdown", @"plist" : @"com.apple.property-list",
            @"doc" : @"com.microsoft.word.doc", @"docx" : @"org.openxmlformats.wordprocessingml.document",
            @"odt" : @"org.oasis-open.opendocument.text",
        } retain];
    return common[ext];
}

#pragma mark - NSDocumentController

@implementation NSDocumentController {
    NSMutableArray<NSDocument *> *_documents;
    NSMutableArray<NSURL *> *_recents;
    NSTimeInterval _autosavingDelay;
}

static NSDocumentController *shared_controller;

/* As Apple's: the first document controller made is the shared one, so an app's subclass made in a nib wins. */
+ (__kindof NSDocumentController *)sharedDocumentController
{
    if (!shared_controller)
        [[self alloc] init];
    return shared_controller;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _documents = [[NSMutableArray alloc] init];
        _recents = [[NSMutableArray alloc] init];
        if (!shared_controller)
            shared_controller = [self retain];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self init];
}

- (void)dealloc
{
    [_documents release];
    [_recents release];
    [super dealloc];
}

- (NSArray<__kindof NSDocument *> *)documents { return [[_documents copy] autorelease]; }

- (void)addDocument:(NSDocument *)document
{
    if ([_documents indexOfObjectIdenticalTo:document] == NSNotFound)
        [_documents addObject:document];
}

- (void)removeDocument:(NSDocument *)document
{
    [[document retain] autorelease];
    [_documents removeObjectIdenticalTo:document];
}

- (__kindof NSDocument *)currentDocument
{
    NSWindow *w = [NSApp mainWindow];
    return [self documentForWindow:w];
}

- (__kindof NSDocument *)documentForWindow:(NSWindow *)window
{
    id doc = [[window windowController] document];
    return [_documents indexOfObjectIdenticalTo:doc] != NSNotFound ? doc : nil;
}

- (__kindof NSDocument *)documentForURL:(NSURL *)url
{
    NSURL *std = [url URLByStandardizingPath];
    for (NSDocument *d in _documents)
        if ([[[d fileURL] URLByStandardizingPath] isEqual:std])
            return d;
    return nil;
}

- (BOOL)hasEditedDocuments
{
    for (NSDocument *d in _documents)
        if ([d isDocumentEdited])
            return YES;
    return NO;
}

/* The app's document types (Info.plist CFBundleDocumentTypes). */
- (NSArray<NSDictionary *> *)_finchDocumentTypes
{
    NSArray *types = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDocumentTypes"];
    return [types isKindOfClass:[NSArray class]] ? types : @[];
}

static NSArray *
type_names(NSDictionary *t)
{
    NSArray *uti = t[@"LSItemContentTypes"];
    if ([uti count])
        return uti;
    return t[@"CFBundleTypeName"] ? @[ t[@"CFBundleTypeName"] ] : @[];
}

- (NSArray<NSString *> *)documentClassNames
{
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *t in [self _finchDocumentTypes]) {
        NSString *c = t[@"NSDocumentClass"];
        if (c && ![names containsObject:c])
            [names addObject:c];
    }
    return names;
}

- (NSString *)defaultType
{
    for (NSDictionary *t in [self _finchDocumentTypes]) {
        NSString *role = t[@"CFBundleTypeRole"];
        if ([role isEqualToString:@"Editor"] || !role)
            return [type_names(t) firstObject];
    }
    return nil;
}

- (Class)documentClassForType:(NSString *)typeName
{
    for (NSDictionary *t in [self _finchDocumentTypes])
        if ([type_names(t) containsObject:typeName] && t[@"NSDocumentClass"])
            return NSClassFromString(t[@"NSDocumentClass"]);
    return nil;
}

- (NSString *)displayNameForType:(NSString *)typeName
{
    for (NSDictionary *t in [self _finchDocumentTypes])
        if ([type_names(t) containsObject:typeName])
            return t[@"CFBundleTypeName"] ?: typeName;
    return typeName;
}

- (NSString *)typeForContentsOfURL:(NSURL *)url error:(NSError **)outError
{
    NSString *ext = [url pathExtension];
    for (NSDictionary *t in [self _finchDocumentTypes])
        for (NSString *e in t[@"CFBundleTypeExtensions"])
            if ([e caseInsensitiveCompare:ext] == NSOrderedSame)
                return [type_names(t) firstObject];
    NSString *uti = uti_for_extension(ext);
    if (uti)
        return uti;
    if (outError)
        *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil];
    return nil;
}

- (NSArray<NSString *> *)allowedTypesForOpenPanel
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *t in [self _finchDocumentTypes])
        [a addObjectsFromArray:type_names(t)];
    return a;
}

#pragma mark Making documents

- (__kindof NSDocument *)makeUntitledDocumentOfType:(NSString *)typeName error:(NSError **)outError
{
    Class c = [self documentClassForType:typeName];
    if (!c) {
        if (outError)
            *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil];
        return nil;
    }
    return [[[c alloc] initWithType:typeName error:outError] autorelease];
}

- (__kindof NSDocument *)makeDocumentWithContentsOfURL:(NSURL *)url ofType:(NSString *)typeName
                                                  error:(NSError **)outError
{
    Class c = [self documentClassForType:typeName];
    if (!c) {
        if (outError)
            *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnknownError userInfo:nil];
        return nil;
    }
    return [[[c alloc] initWithContentsOfURL:url ofType:typeName error:outError] autorelease];
}

- (__kindof NSDocument *)makeDocumentForURL:(NSURL *)urlOrNil withContentsOfURL:(NSURL *)contentsURL
                                     ofType:(NSString *)typeName error:(NSError **)outError
{
    Class c = [self documentClassForType:typeName];
    return c ? [[[c alloc] initForURL:urlOrNil withContentsOfURL:contentsURL ofType:typeName error:outError] autorelease]
             : nil;
}

- (id)openUntitledDocumentAndDisplay:(BOOL)display error:(NSError **)outError
{
    NSDocument *d = [self makeUntitledDocumentOfType:[self defaultType] error:outError];
    if (!d)
        return nil;
    [self addDocument:d];
    if (display) {
        [d makeWindowControllers];
        [d showWindows];
    }
    return d;
}

- (void)openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)display
                    completionHandler:(void (^)(NSDocument *, BOOL, NSError *))completionHandler
{
    NSDocument *existing = [self documentForURL:url];
    if (existing) {
        if (display)
            [existing showWindows];
        if (completionHandler)
            completionHandler(existing, YES, nil);
        return;
    }
    NSError *error = nil;
    NSString *type = [self typeForContentsOfURL:url error:&error];
    NSDocument *d = type ? [self makeDocumentWithContentsOfURL:url ofType:type error:&error] : nil;
    if (d) {
        [self addDocument:d];
        [self noteNewRecentDocument:d];
        if (display) {
            [d makeWindowControllers];
            [d showWindows];
        }
    }
    if (completionHandler)
        completionHandler(d, NO, error);
    else if (!d && error)
        [self presentError:error];
}

- (id)openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)display error:(NSError **)outError
{
    __block NSDocument *result = nil;
    __block NSError *error = nil;
    [self openDocumentWithContentsOfURL:url display:display
                      completionHandler:^(NSDocument *d, BOOL already, NSError *e) {
                          result = d;
                          error = [e retain];
                      }];
    if (outError)
        *outError = [error autorelease];
    else
        [error release];
    return result;
}

- (IBAction)newDocument:(id)sender
{
    NSError *error = nil;
    if (![self openUntitledDocumentAndDisplay:YES error:&error] && error)
        [self presentError:error];
}

- (IBAction)openDocument:(id)sender
{
    NSArray *urls = [self URLsFromRunningOpenPanel];
    for (NSURL *u in urls)
        [self openDocumentWithContentsOfURL:u display:YES
                          completionHandler:^(NSDocument *d, BOOL already, NSError *e) {
                              if (!d && e)
                                  [self presentError:e];
                          }];
}

- (NSArray<NSURL *> *)URLsFromRunningOpenPanel
{
    Class panel = FINCH_CLASS(NSOpenPanel);
    if (!panel) {
        NSLog(@"Finch: no open panel yet");
        return nil;
    }
    NSOpenPanel *p = [panel openPanel];
    [p setAllowsMultipleSelection:YES];
    return [p runModal] == NSModalResponseOK ? [p URLs] : nil;
}

- (NSInteger)runModalOpenPanel:(NSOpenPanel *)openPanel forTypes:(NSArray<NSString *> *)types
{
    return [openPanel runModal];
}

- (IBAction)saveAllDocuments:(id)sender
{
    for (NSDocument *d in [self documents])
        if ([d isDocumentEdited])
            [d saveDocument:sender];
}

- (void)closeAllDocumentsWithDelegate:(id)delegate didCloseAllSelector:(SEL)didCloseAllSelector
                          contextInfo:(void *)contextInfo
{
    for (NSDocument *d in [self documents])
        [d close];
    if (delegate && didCloseAllSelector)
        ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, didCloseAllSelector, self, YES, contextInfo);
}

- (void)reviewUnsavedDocumentsWithAlertTitle:(NSString *)title cancellable:(BOOL)cancellable
                                    delegate:(id)delegate didReviewAllSelector:(SEL)didReviewAllSelector
                                 contextInfo:(void *)contextInfo
{
    if (delegate && didReviewAllSelector)
        ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, didReviewAllSelector, self, YES, contextInfo);
}

#pragma mark Recents and settings

- (NSUInteger)maximumRecentDocumentCount { return 10; }
- (NSArray<NSURL *> *)recentDocumentURLs { return [[_recents copy] autorelease]; }

- (void)noteNewRecentDocumentURL:(NSURL *)url
{
    if (!url)
        return;
    [_recents removeObject:url];
    [_recents insertObject:url atIndex:0];
    while ([_recents count] > [self maximumRecentDocumentCount])
        [_recents removeLastObject];
}

- (void)noteNewRecentDocument:(NSDocument *)document
{
    [self noteNewRecentDocumentURL:[document fileURL]];
}

- (IBAction)clearRecentDocuments:(id)sender
{
    [_recents removeAllObjects];
}

- (NSTimeInterval)autosavingDelay { return _autosavingDelay; }
- (void)setAutosavingDelay:(NSTimeInterval)delay { _autosavingDelay = delay; }
- (BOOL)allowsAutomaticShareMenu { return NO; }

- (BOOL)presentError:(NSError *)error
{
    return [NSApp presentError:error];
}

- (NSError *)willPresentError:(NSError *)error
{
    return error;
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    if ([item action] == @selector(saveAllDocuments:))
        return [self hasEditedDocuments];
    if ([item action] == @selector(clearRecentDocuments:))
        return [_recents count] > 0;
    return YES;
}

@end

#pragma mark - NSDocument

@implementation NSDocument {
    NSURL *_fileURL;
    NSString *_fileType;
    NSDate *_modificationDate;
    NSMutableArray<NSWindowController *> *_windowControllers;
    NSUndoManager *_undoManager;
    NSInteger _changeCount;
    NSString *_displayName;  /* the untitled name, once given */
    NSInteger _untitledNumber;
    NSPrintInfo *_printInfo;
    BOOL _hasUndoManager;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _windowControllers = [[NSMutableArray alloc] init];
        _hasUndoManager = YES;
    }
    return self;
}

- (instancetype)initWithType:(NSString *)typeName error:(NSError **)outError
{
    self = [self init];
    if (self)
        [self setFileType:typeName];
    return self;
}

- (instancetype)initWithContentsOfURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError
{
    self = [self init];
    if (!self)
        return nil;
    if (![self readFromURL:url ofType:typeName error:outError]) {
        [self release];
        return nil;
    }
    [self setFileURL:url];
    [self setFileType:typeName];
    [self setFileModificationDate:[[[NSFileManager defaultManager] attributesOfItemAtPath:[url path] error:NULL]
                                      fileModificationDate]];
    return self;
}

- (instancetype)initForURL:(NSURL *)urlOrNil withContentsOfURL:(NSURL *)contentsURL ofType:(NSString *)typeName
                     error:(NSError **)outError
{
    self = [self initWithContentsOfURL:contentsURL ofType:typeName error:outError];
    if (self)
        [self setFileURL:urlOrNil];
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_fileURL release];
    [_fileType release];
    [_modificationDate release];
    [_windowControllers release];
    [_undoManager release];
    [_displayName release];
    [_printInfo release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p>", [self class], self];
}

+ (BOOL)autosavesInPlace { return NO; }
+ (BOOL)autosavesDrafts { return NO; }
+ (BOOL)preservesVersions { return NO; }
+ (BOOL)usesUbiquitousStorage { return NO; }
+ (BOOL)isNativeType:(NSString *)type { return YES; }
+ (NSArray<NSString *> *)readableTypes { return @[]; }
+ (NSArray<NSString *> *)writableTypes { return @[]; }
+ (BOOL)canConcurrentlyReadDocumentsOfType:(NSString *)typeName { return NO; }

- (NSURL *)fileURL { return _fileURL; }

- (void)setFileURL:(NSURL *)url
{
    [_fileURL autorelease];
    _fileURL = [url copy];
    for (NSWindowController *wc in _windowControllers)
        [wc synchronizeWindowTitleWithDocumentName];
}

- (NSString *)fileType { return _fileType; }
- (void)setFileType:(NSString *)type { [_fileType autorelease]; _fileType = [type copy]; }
- (NSDate *)fileModificationDate { return _modificationDate; }
- (void)setFileModificationDate:(NSDate *)date { [_modificationDate autorelease]; _modificationDate = [date copy]; }
- (BOOL)isLocked { return NO; }
- (BOOL)isInViewingMode { return NO; }
- (BOOL)isBrowsingVersions { return NO; }
- (BOOL)hasUnautosavedChanges { return _changeCount != 0; }
- (NSString *)autosavingFileType { return _fileType; }

/* "Untitled", "Untitled 2", ...: one more than the highest number the controller's untitled documents have. */
- (NSString *)displayName
{
    if (_fileURL) {
        NSString *name = nil;
        if ([_fileURL respondsToSelector:@selector(getResourceValue:forKey:error:)] &&
            [_fileURL getResourceValue:&name forKey:NSURLLocalizedNameKey error:NULL] && name)
            return name;
        return [_fileURL lastPathComponent];
    }
    if (!_displayName) {
        NSInteger highest = 0;
        for (NSDocument *d in [[NSDocumentController sharedDocumentController] documents])
            highest = MAX(highest, d->_untitledNumber);
        _untitledNumber = highest + 1;
        _displayName = _untitledNumber == 1 ? @"Untitled"
                                            : [[NSString alloc] initWithFormat:@"Untitled %ld", (long)_untitledNumber];
    }
    return _displayName;
}

- (void)setDisplayName:(NSString *)name
{
    [_displayName autorelease];
    _displayName = [name copy];
}

#pragma mark Windows

- (NSString *)windowNibName { return nil; }
- (void)windowControllerWillLoadNib:(NSWindowController *)controller {}
- (void)windowControllerDidLoadNib:(NSWindowController *)controller {}
- (NSArray<NSWindowController *> *)windowControllers { return [[_windowControllers copy] autorelease]; }

- (void)makeWindowControllers
{
    NSString *nib = [self windowNibName];
    if (!nib)
        return;
    NSWindowController *wc = [[NSWindowController alloc] initWithWindowNibName:nib owner:self];
    [self addWindowController:wc];
    [wc release];
}

- (void)addWindowController:(NSWindowController *)controller
{
    if ([_windowControllers indexOfObjectIdenticalTo:controller] != NSNotFound)
        return;
    [_windowControllers addObject:controller];
    if ([controller document] != self)
        [controller setDocument:self];
}

- (void)removeWindowController:(NSWindowController *)controller
{
    [[controller retain] autorelease];
    [_windowControllers removeObjectIdenticalTo:controller];
    if ([controller document] == self)
        [controller setDocument:nil];
}

- (void)showWindows
{
    for (NSWindowController *wc in [self windowControllers])
        [wc showWindow:self];
}

- (NSWindow *)windowForSheet
{
    NSWindow *w = [[_windowControllers firstObject] window];
    return w ?: [NSApp mainWindow];
}

- (void)setWindow:(NSWindow *)window
{
    [[_windowControllers firstObject] setWindow:window];
}

- (void)shouldCloseWindowController:(NSWindowController *)controller delegate:(id)delegate
                shouldCloseSelector:(SEL)shouldCloseSelector contextInfo:(void *)contextInfo
{
    if (delegate && shouldCloseSelector)
        ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, shouldCloseSelector, self, YES, contextInfo);
}

- (void)canCloseDocumentWithDelegate:(id)delegate shouldCloseSelector:(SEL)shouldCloseSelector
                         contextInfo:(void *)contextInfo
{
    if (delegate && shouldCloseSelector)
        ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, shouldCloseSelector, self, YES, contextInfo);
}

- (void)close
{
    [self retain];
    for (NSWindowController *wc in [self windowControllers]) {
        [wc close];
        [self removeWindowController:wc];
    }
    [[NSDocumentController sharedDocumentController] removeDocument:self];
    [self release];
}

#pragma mark Changes and undo

- (BOOL)isDocumentEdited { return _changeCount != 0; }

- (void)updateChangeCount:(NSDocumentChangeType)change
{
    switch (change & 0xff) {
    case NSChangeDone:
    case NSChangeRedone:
        _changeCount++;
        break;
    case NSChangeUndone:
        _changeCount--;
        break;
    case NSChangeCleared:
    case NSChangeReadOtherContents:
        _changeCount = 0;
        break;
    default:
        break;
    }
    for (NSWindowController *wc in _windowControllers)
        [wc setDocumentEdited:[self isDocumentEdited]];
}

- (id)changeCountTokenForSaveOperation:(NSSaveOperationType)op { return @(_changeCount); }
- (void)updateChangeCountWithToken:(id)token forSaveOperation:(NSSaveOperationType)op
{
    if ([token integerValue] == _changeCount)
        [self updateChangeCount:NSChangeCleared];
}

- (BOOL)hasUndoManager { return _hasUndoManager; }

- (void)setHasUndoManager:(BOOL)flag
{
    _hasUndoManager = flag;
    if (!flag)
        [self setUndoManager:nil];
}

- (NSUndoManager *)undoManager
{
    if (!_undoManager && _hasUndoManager) {
        NSUndoManager *u = [[NSUndoManager alloc] init];
        [self setUndoManager:u];
        [u release];
    }
    return _undoManager;
}

/* As Apple's: closing an undo group marks a change; undoing and redoing step the count. */
- (void)setUndoManager:(NSUndoManager *)manager
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    if (_undoManager) {
        [nc removeObserver:self name:nil object:_undoManager];
        [_undoManager release];
    }
    _undoManager = [manager retain];
    if (manager) {
        [nc addObserver:self selector:@selector(_finchUndoChange:) name:NSUndoManagerDidCloseUndoGroupNotification
                 object:manager];
        [nc addObserver:self selector:@selector(_finchUndoChange:) name:NSUndoManagerDidUndoChangeNotification
                 object:manager];
        [nc addObserver:self selector:@selector(_finchUndoChange:) name:NSUndoManagerDidRedoChangeNotification
                 object:manager];
    }
}

- (void)_finchUndoChange:(NSNotification *)note
{
    NSString *name = [note name];
    if ([name isEqualToString:NSUndoManagerDidUndoChangeNotification])
        [self updateChangeCount:NSChangeUndone];
    else if ([name isEqualToString:NSUndoManagerDidRedoChangeNotification])
        [self updateChangeCount:NSChangeRedone];
    else if ([[note object] groupingLevel] == 0 && ![[note object] isUndoing] && ![[note object] isRedoing])
        [self updateChangeCount:NSChangeDone];
}

#pragma mark Reading and writing

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError
{
    BOOL dir = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:[url path] isDirectory:&dir];
    if (dir) {
        NSFileWrapper *w = [[[NSFileWrapper alloc] initWithURL:url options:0 error:outError] autorelease];
        return w && [self readFromFileWrapper:w ofType:typeName error:outError];
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:outError];
    return data && [self readFromData:data ofType:typeName error:outError];
}

- (BOOL)readFromFileWrapper:(NSFileWrapper *)wrapper ofType:(NSString *)typeName error:(NSError **)outError
{
    NSData *d = [wrapper regularFileContents];
    return d && [self readFromData:d ofType:typeName error:outError];
}

- (BOOL)readFromData:(NSData *)data ofType:(NSString *)typeName error:(NSError **)outError
{
    [NSException raise:NSInternalInconsistencyException
                format:@"%@ must implement readFromData:ofType:error: or another reading method", [self class]];
    return NO;
}

- (BOOL)revertToContentsOfURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError
{
    if (![self readFromURL:url ofType:typeName error:outError])
        return NO;
    [self updateChangeCount:NSChangeCleared];
    [[self undoManager] removeAllActions];
    return YES;
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError
{
    [NSException raise:NSInternalInconsistencyException
                format:@"%@ must implement dataOfType:error: or another writing method", [self class]];
    return nil;
}

- (NSFileWrapper *)fileWrapperOfType:(NSString *)typeName error:(NSError **)outError
{
    NSData *d = [self dataOfType:typeName error:outError];
    return d ? [[[NSFileWrapper alloc] initRegularFileWithContents:d] autorelease] : nil;
}

- (BOOL)writeToURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError **)outError
{
    NSFileWrapper *w = [self fileWrapperOfType:typeName error:outError];
    return w && [w writeToURL:url options:NSFileWrapperWritingAtomic originalContentsURL:nil error:outError];
}

- (BOOL)writeToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)op
    originalContentsURL:(NSURL *)absoluteOriginalContentsURL error:(NSError **)outError
{
    return [self writeToURL:url ofType:typeName error:outError];
}

- (BOOL)writeSafelyToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)op
                   error:(NSError **)outError
{
    return [self writeToURL:url ofType:typeName forSaveOperation:op originalContentsURL:_fileURL error:outError];
}

- (NSDictionary<NSString *, id> *)fileAttributesToWriteToURL:(NSURL *)url ofType:(NSString *)typeName
                                            forSaveOperation:(NSSaveOperationType)op
                                         originalContentsURL:(NSURL *)original
                                                       error:(NSError **)outError
{
    return @{};
}

- (void)saveToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)op
    completionHandler:(void (^)(NSError *))completionHandler
{
    NSError *error = nil;
    id token = [self changeCountTokenForSaveOperation:op];
    BOOL ok = [self writeSafelyToURL:url ofType:typeName forSaveOperation:op error:&error];
    if (ok && op != NSSaveToOperation) {
        [self setFileURL:url];
        [self setFileType:typeName];
        [self setFileModificationDate:[NSDate date]];
        [self updateChangeCountWithToken:token forSaveOperation:op];
        [[NSDocumentController sharedDocumentController] noteNewRecentDocument:self];
    }
    if (completionHandler)
        completionHandler(ok ? nil : error);
    else if (!ok && error)
        [self presentError:error];
}

- (void)saveToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)op
             delegate:(id)delegate didSaveSelector:(SEL)didSaveSelector contextInfo:(void *)contextInfo
{
    [self saveToURL:url ofType:typeName forSaveOperation:op completionHandler:^(NSError *error) {
        if (delegate && didSaveSelector)
            ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, didSaveSelector, self, error == nil,
                                                                 contextInfo);
    }];
}

- (BOOL)prepareSavePanel:(NSSavePanel *)savePanel { return YES; }
- (BOOL)shouldRunSavePanelWithAccessoryView { return YES; }

- (void)runModalSavePanelForSaveOperation:(NSSaveOperationType)op delegate:(id)delegate
                          didSaveSelector:(SEL)didSaveSelector contextInfo:(void *)contextInfo
{
    Class panelClass = FINCH_CLASS(NSSavePanel);
    if (!panelClass) {
        NSLog(@"Finch: no save panel yet");
        return;
    }
    NSSavePanel *p = [panelClass savePanel];
    [p setNameFieldStringValue:[self displayName]];
    if (![self prepareSavePanel:p] || [p runModal] != NSModalResponseOK)
        return;
    [self saveToURL:[p URL] ofType:_fileType forSaveOperation:op delegate:delegate didSaveSelector:didSaveSelector
        contextInfo:contextInfo];
}

- (IBAction)saveDocument:(id)sender
{
    if (_fileURL)
        [self saveToURL:_fileURL ofType:_fileType forSaveOperation:NSSaveOperation
            completionHandler:^(NSError *e) {
                if (e)
                    [self presentError:e];
            }];
    else
        [self runModalSavePanelForSaveOperation:NSSaveAsOperation delegate:nil didSaveSelector:NULL contextInfo:NULL];
}

- (IBAction)saveDocumentAs:(id)sender
{
    [self runModalSavePanelForSaveOperation:NSSaveAsOperation delegate:nil didSaveSelector:NULL contextInfo:NULL];
}

- (IBAction)saveDocumentTo:(id)sender
{
    [self runModalSavePanelForSaveOperation:NSSaveToOperation delegate:nil didSaveSelector:NULL contextInfo:NULL];
}

- (IBAction)revertDocumentToSaved:(id)sender
{
    if (_fileURL)
        [self revertToContentsOfURL:_fileURL ofType:_fileType error:NULL];
}

- (void)autosaveWithImplicitCancellability:(BOOL)implicit completionHandler:(void (^)(NSError *))handler
{
    if (handler)
        handler(nil);
}

- (BOOL)checkAutosavingSafetyAndReturnError:(NSError **)outError { return YES; }
- (void)scheduleAutosaving {}
- (IBAction)runPageLayout:(id)sender {}
- (IBAction)printDocument:(id)sender {}
- (NSPrintInfo *)printInfo { return _printInfo; }
- (void)setPrintInfo:(NSPrintInfo *)info { [_printInfo autorelease]; _printInfo = [info retain]; }

- (BOOL)presentError:(NSError *)error
{
    return [[NSDocumentController sharedDocumentController] presentError:[self willPresentError:error]];
}

- (NSError *)willPresentError:(NSError *)error
{
    return error;
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item
{
    SEL a = [item action];
    if (a == @selector(revertDocumentToSaved:))
        return _fileURL != nil && [self isDocumentEdited];
    if (a == @selector(saveDocument:))
        return YES;
    return YES;
}

@end
