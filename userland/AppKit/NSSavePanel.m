/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSSavePanel and NSOpenPanel (docs/design/APPKIT.md): Finch's own file
 * browser panel, with Apple's API and state as measured on macOS 26.
 *
 * The panel, top to bottom: the message, the "Save As:" row (save panels),
 * a row with a back button, a pop-up of the folder's path and a New Folder
 * button (when the panel can create folders), the folder's contents as a
 * list (FinchFileList: an icon and a name a row; folders open with a double
 * click or Command-Down, Command-Up goes to the enclosing folder, arrows move
 * the selection, typing selects by name), the accessory view, and the
 * buttons: Cancel and the prompt, with "Hide extension" at the left of a save
 * panel that offers it. Return chooses, Escape cancels.
 *
 * What is shown follows the panel's settings: hidden files only with
 * showsHiddenFiles; packages are files unless treatsFilePackagesAsDirectories;
 * files are enabled when their type (UniformTypeIdentifiers) conforms to one
 * of allowedContentTypes and, in an open panel, when files can be chosen; the
 * delegate's panel:shouldEnableURL: has the last word. Choosing in a save
 * panel appends the first allowed type's extension to a name without an
 * allowed one, asks before replacing a file, and asks the delegate's
 * panel:validateURL:error:. Until then, as Apple's, URL is the directory
 * and the name joined.
 */
#import "FinchPanels.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface NSSavePanel ()
- (BOOL)_finchIsOpenPanel;
- (void)_finchActivateEntryAtIndex:(NSUInteger)index;
- (void)_finchSelectionChanged;
- (void)_finchGoToEnclosingFolder;
@end

#pragma mark - The file list

@interface FinchFileEntry : NSObject {
@public
    NSURL *url;
    NSString *name;
    BOOL directory;  /* navigable: a folder, or a package treated as one */
    BOOL enabled;
    FinchIconKind icon;
}
@end

@implementation FinchFileEntry
- (void)dealloc
{
    [url release];
    [name release];
    [super dealloc];
}
@end

@interface FinchFileList : NSView {
@public
    NSArray<FinchFileEntry *> *_entries;
    NSMutableIndexSet *_selection;
    NSSavePanel *_panel;  /* not retained */
    BOOL _multiple;
    NSUInteger _anchor;
    NSMutableString *_typed;
    NSTimeInterval _typedAt;
}
@end

static const CGFloat kRowHeight = 22;

static NSImage *
small_icon(FinchIconKind kind)
{
    static NSMutableDictionary *cache;
    if (!cache)
        cache = [[NSMutableDictionary alloc] init];
    NSImage *i = cache[@(kind)];
    if (!i) {
        i = FinchIconImage(kind, 16);
        cache[@(kind)] = i;
    }
    return i;
}

@implementation FinchFileList

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        _entries = [@[] retain];
        _selection = [[NSMutableIndexSet alloc] init];
        _typed = [[NSMutableString alloc] init];
        _anchor = NSNotFound;
    }
    return self;
}

- (void)dealloc
{
    [_entries release];
    [_selection release];
    [_typed release];
    [super dealloc];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isOpaque { return YES; }

- (void)setEntries:(NSArray *)entries
{
    [_entries autorelease];
    _entries = [entries copy];
    [_selection removeAllIndexes];
    _anchor = NSNotFound;
    [self sizeToRows];
    [self setNeedsDisplay:YES];
}

- (void)sizeToRows
{
    NSView *clip = [self superview];
    CGFloat w = clip ? [clip bounds].size.width : [self frame].size.width;
    CGFloat h = MAX(_entries.count * kRowHeight, clip ? [clip bounds].size.height : 0);
    [self setFrameSize:NSMakeSize(w, h)];
}

- (void)drawRect:(NSRect)dirty
{
    [[NSColor whiteColor] setFill];
    NSRectFill(dirty);
    NSFont *font = [NSFont systemFontOfSize:13];
    BOOL key = [[self window] isKeyWindow] && [[self window] firstResponder] == self;
    NSColor *accent = [NSColor colorWithSRGBRed:0 green:122 / 255.0 blue:1 alpha:1];
    NSColor *unfocused = [NSColor colorWithSRGBRed:0.84 green:0.86 blue:0.90 alpha:1];
    NSUInteger first = (NSUInteger)MAX(0, floor(NSMinY(dirty) / kRowHeight));
    for (NSUInteger i = first; i < _entries.count && i * kRowHeight < NSMaxY(dirty); i++) {
        FinchFileEntry *e = _entries[i];
        NSRect row = NSMakeRect(0, i * kRowHeight, [self bounds].size.width, kRowHeight);
        BOOL selected = [_selection containsIndex:i];
        if (selected) {
            [(key ? accent : unfocused) setFill];
            NSRectFill(row);
        } else if (i % 2) {
            [[NSColor colorWithSRGBRed:0.965 green:0.97 blue:0.98 alpha:1] setFill];
            NSRectFill(row);
        }
        [small_icon(e->icon) drawInRect:NSMakeRect(8, row.origin.y + 3, 16, 16) fromRect:NSZeroRect
                              operation:NSCompositingOperationSourceOver
                               fraction:e->enabled ? 1 : 0.4
                         respectFlipped:YES
                                  hints:nil];
        NSColor *ink = selected && key ? [NSColor whiteColor]
                       : e->enabled    ? [NSColor labelColor]
                                       : [NSColor colorWithSRGBRed:0.6 green:0.6 blue:0.6 alpha:1];
        NSDictionary *attrs = @{NSFontAttributeName : font, NSForegroundColorAttributeName : ink};
        [e->name drawInRect:NSMakeRect(30, row.origin.y + 3, row.size.width - 50, 17) withAttributes:attrs];
        if (e->directory)
            [@"›" drawAtPoint:NSMakePoint(row.size.width - 16, row.origin.y + 2) withAttributes:attrs];
    }
}

- (NSUInteger)rowAtPoint:(NSPoint)p
{
    if (p.y < 0)
        return NSNotFound;
    NSUInteger r = (NSUInteger)(p.y / kRowHeight);
    return r < _entries.count ? r : NSNotFound;
}

- (void)scrollRowToVisible:(NSUInteger)row
{
    if (row != NSNotFound)
        [self scrollRectToVisible:NSMakeRect(0, row * kRowHeight, 1, kRowHeight)];
}

- (void)selectRow:(NSUInteger)row extend:(BOOL)extend toggle:(BOOL)toggle
{
    if (row == NSNotFound || !_entries[row]->enabled) {
        if (!extend && !toggle && _selection.count) {
            [_selection removeAllIndexes];
            [self setNeedsDisplay:YES];
            [_panel _finchSelectionChanged];
        }
        return;
    }
    if (!_multiple)
        extend = toggle = NO;
    if (toggle) {
        if ([_selection containsIndex:row])
            [_selection removeIndex:row];
        else
            [_selection addIndex:row];
        _anchor = row;
    } else if (extend && _anchor != NSNotFound) {
        [_selection removeAllIndexes];
        NSUInteger a = MIN(_anchor, row), b = MAX(_anchor, row);
        for (NSUInteger i = a; i <= b; i++)
            if (_entries[i]->enabled)
                [_selection addIndex:i];
    } else {
        [_selection removeAllIndexes];
        [_selection addIndex:row];
        _anchor = row;
    }
    [self scrollRowToVisible:row];
    [self setNeedsDisplay:YES];
    [_panel _finchSelectionChanged];
}

- (void)mouseDown:(NSEvent *)event
{
    [[self window] makeFirstResponder:self];
    NSUInteger row = [self rowAtPoint:[self convertPoint:[event locationInWindow] fromView:nil]];
    NSEventModifierFlags m = [event modifierFlags];
    [self selectRow:row extend:(m & NSEventModifierFlagShift) != 0 toggle:(m & NSEventModifierFlagCommand) != 0];
    if ([event clickCount] == 2 && row != NSNotFound && _entries[row]->enabled)
        [_panel _finchActivateEntryAtIndex:row];
}

/* The next enabled row from `from`, going by `step`. */
- (NSUInteger)enabledRowFrom:(NSInteger)from step:(NSInteger)step
{
    for (NSInteger i = from; i >= 0 && i < (NSInteger)_entries.count; i += step)
        if (_entries[i]->enabled)
            return i;
    return NSNotFound;
}

- (void)keyDown:(NSEvent *)event
{
    NSString *chars = [event charactersIgnoringModifiers];
    unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    NSEventModifierFlags m = [event modifierFlags];
    BOOL command = (m & NSEventModifierFlagCommand) != 0;
    if (c == NSUpArrowFunctionKey && command) {
        [_panel _finchGoToEnclosingFolder];
        return;
    }
    if (c == NSDownArrowFunctionKey && command) {
        NSUInteger r = [_selection firstIndex];
        if (r != NSNotFound)
            [_panel _finchActivateEntryAtIndex:r];
        return;
    }
    if (c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey) {
        NSInteger step = c == NSUpArrowFunctionKey ? -1 : 1;
        NSUInteger cur = c == NSUpArrowFunctionKey ? [_selection firstIndex] : [_selection lastIndex];
        NSUInteger r = cur == NSNotFound ? [self enabledRowFrom:step > 0 ? 0 : (NSInteger)_entries.count - 1 step:step]
                                         : [self enabledRowFrom:(NSInteger)cur + step step:step];
        if (r != NSNotFound)
            [self selectRow:r extend:(m & NSEventModifierFlagShift) != 0 toggle:NO];
        return;
    }
    if (!command && c > ' ' && c < 0xF700 && c != 0x7f) {
        /* type to select */
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - _typedAt > 1.0)
            [_typed setString:@""];
        _typedAt = now;
        [_typed appendString:[event characters] ?: chars];
        for (NSUInteger i = 0; i < _entries.count; i++)
            if (_entries[i]->enabled &&
                [_entries[i]->name rangeOfString:_typed options:NSCaseInsensitiveSearch | NSAnchoredSearch].location !=
                    NSNotFound) {
                [self selectRow:i extend:NO toggle:NO];
                break;
            }
        return;
    }
    [super keyDown:event];
}

- (BOOL)becomeFirstResponder
{
    [self setNeedsDisplay:YES];
    return YES;
}

- (BOOL)resignFirstResponder
{
    [self setNeedsDisplay:YES];
    return YES;
}

@end

#pragma mark - NSSavePanel

@implementation NSSavePanel {
    NSString *_title, *_prompt, *_message, *_nameFieldLabel, *_name, *_identifier;
    NSURL *_directoryURL, *_finalURL;
    BOOL _directoryInvalid;
    NSArray<UTType *> *_allowedTypes;
    NSArray<NSString *> *_allowedFileTypes;
    BOOL _allowsOtherFileTypes, _canCreateDirectories, _canSelectHiddenExtension, _extensionHidden;
    BOOL _treatsPackagesAsDirectories, _showsHiddenFiles, _showsTagField, _showsContentTypes;
    NSArray<NSString *> *_tagNames;
    NSView *_accessory;
    id<NSOpenSavePanelDelegate> _delegate;
    NSMutableArray<NSURL *> *_history;
    BOOL _modal, _shown;
    NSWindow *_sheetParent;
    void (^_handler)(NSModalResponse);
    NSString *_hiddenExtension;  /* the extension the name field isn't showing */
@protected
    /* views */
    NSTextField *_messageLabel, *_nameLabel, *_nameField;
    NSButton *_backButton, *_newFolderButton, *_okButton, *_cancelButton, *_hideExtensionButton;
    NSPopUpButton *_pathPopUp;
    NSScrollView *_scroll;
    FinchFileList *_list;
    NSView *_accessoryHolder;
}

+ (NSSavePanel *)savePanel
{
    return [[[self alloc] init] autorelease];
}

- (BOOL)_finchIsOpenPanel { return NO; }

- (instancetype)init
{
    BOOL open = [self _finchIsOpenPanel];
    NSWindowStyleMask style = NSWindowStyleMaskTitled | (open ? NSWindowStyleMaskResizable : 0);
    return [self initWithContentRect:NSMakeRect(0, 0, 580, open ? 400 : 420) styleMask:style
                             backing:NSBackingStoreBuffered defer:YES];
}

- (instancetype)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing defer:(BOOL)flag
{
    if (!(self = [super initWithContentRect:contentRect styleMask:style backing:backing defer:flag]))
        return nil;
    BOOL open = [self _finchIsOpenPanel];
    [self setReleasedWhenClosed:NO];
    [self setHidesOnDeactivate:NO];
    _name = @"Untitled";
    _canCreateDirectories = !open;
    _showsTagField = !open;
    _tagNames = open ? nil : [@[] retain];
    _allowedTypes = [@[] retain];
    _history = [[NSMutableArray alloc] init];
    [super setTitle:[self _finchDefaultTitle]];
    [self _finchMakeViews];
    return self;
}

- (void)dealloc
{
    [_title release];
    [_prompt release];
    [_message release];
    [_nameFieldLabel release];
    [_name release];
    [_identifier release];
    [_directoryURL release];
    [_finalURL release];
    [_allowedTypes release];
    [_allowedFileTypes release];
    [_tagNames release];
    [_accessory release];
    [_history release];
    [_handler release];
    [_hiddenExtension release];
    [_messageLabel release];
    [_nameLabel release];
    [_nameField release];
    [_backButton release];
    [_newFolderButton release];
    [_okButton release];
    [_cancelButton release];
    [_hideExtensionButton release];
    [_pathPopUp release];
    [_scroll release];
    [_list release];
    [_accessoryHolder release];
    [super dealloc];
}

- (NSString *)_finchDefaultTitle { return [self _finchIsOpenPanel] ? @"Open" : @"Save"; }

#pragma mark Properties

- (NSString *)title { return _title ?: [self _finchDefaultTitle]; }

- (void)setTitle:(NSString *)title
{
    [_title autorelease];
    _title = title.length ? [title copy] : nil;
    [super setTitle:[self title]];
}

- (NSString *)prompt { return _prompt ?: [self _finchDefaultTitle]; }

- (void)setPrompt:(NSString *)prompt
{
    [_prompt autorelease];
    _prompt = prompt.length ? [prompt copy] : nil;
    [_okButton setTitle:[self prompt]];
}

- (NSString *)message { return _message ?: @""; }

- (void)setMessage:(NSString *)message
{
    [_message autorelease];
    _message = [message copy];
}

- (NSString *)nameFieldLabel
{
    if (_nameFieldLabel)
        return _nameFieldLabel;
    return [self _finchIsOpenPanel] ? nil : @"Save As:";
}

- (void)setNameFieldLabel:(NSString *)label
{
    [_nameFieldLabel autorelease];
    _nameFieldLabel = [label copy];
    [_nameLabel setStringValue:[self nameFieldLabel] ?: @""];
}

- (NSString *)nameFieldStringValue
{
    if (_shown && ![self _finchIsOpenPanel])
        return [self _finchTypedName];
    return _name;
}

- (void)setNameFieldStringValue:(NSString *)value
{
    if ([self _finchIsOpenPanel])
        return;  /* as Apple's: an open panel keeps "Untitled" */
    [_name autorelease];
    _name = [(value ?: @"") copy];
    [self _finchShowName];
}

- (NSURL *)directoryURL
{
    if (_directoryInvalid)
        return nil;
    if (_directoryURL)
        return _directoryURL;
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] isDirectory:YES];
}

- (void)setDirectoryURL:(NSURL *)url
{
    [_directoryURL autorelease];
    _directoryURL = nil;
    _directoryInvalid = url && ![url isFileURL];
    if (url && [url isFileURL])
        _directoryURL = [url copy];
    if (_shown)
        [self _finchReload];
}

- (NSURL *)URL
{
    if (_finalURL)
        return _finalURL;
    NSURL *dir = [self directoryURL];
    return dir && _name.length ? [dir URLByAppendingPathComponent:_name] : dir;
}

- (NSArray<UTType *> *)allowedContentTypes { return _allowedTypes; }

- (void)setAllowedContentTypes:(NSArray<UTType *> *)types
{
    [_allowedTypes autorelease];
    _allowedTypes = [(types ?: @[]) copy];
    [_allowedFileTypes autorelease];
    _allowedFileTypes = nil;
    if (_allowedTypes.count) {
        NSMutableArray *ids = [NSMutableArray array];
        for (UTType *t in _allowedTypes)
            [ids addObject:[t identifier]];
        _allowedFileTypes = [ids copy];
    }
    if (_shown)
        [self _finchReload];
}

- (NSArray<NSString *> *)allowedFileTypes { return _allowedFileTypes; }

- (void)setAllowedFileTypes:(NSArray<NSString *> *)fileTypes
{
    Class ut = FinchUTTypeClass();
    NSMutableArray *types = [NSMutableArray array];
    for (NSString *s in fileTypes) {
        UTType *t = [s containsString:@"."] ? [ut typeWithIdentifier:s] : nil;
        if (!t)
            t = [ut typeWithFilenameExtension:s];
        if (t && ![types containsObject:t])
            [types addObject:t];
    }
    [_allowedTypes autorelease];
    _allowedTypes = [types copy];
    [_allowedFileTypes autorelease];
    _allowedFileTypes = [fileTypes copy];  /* as Apple's: an empty array stays one */
    if (_shown)
        [self _finchReload];
}

- (BOOL)allowsOtherFileTypes { return _allowsOtherFileTypes; }
- (void)setAllowsOtherFileTypes:(BOOL)flag { _allowsOtherFileTypes = flag; }
- (BOOL)canCreateDirectories { return _canCreateDirectories; }
- (void)setCanCreateDirectories:(BOOL)flag { _canCreateDirectories = flag; [_newFolderButton setHidden:!flag]; }
- (BOOL)canSelectHiddenExtension { return _canSelectHiddenExtension; }
- (void)setCanSelectHiddenExtension:(BOOL)flag { _canSelectHiddenExtension = flag; }
- (BOOL)isExtensionHidden { return _extensionHidden; }

- (void)setExtensionHidden:(BOOL)flag
{
    if (_shown)
        [self _finchStoreTypedName];
    _extensionHidden = flag;
    [_hideExtensionButton setState:flag ? NSControlStateValueOn : NSControlStateValueOff];
    [self _finchShowName];
}

- (BOOL)treatsFilePackagesAsDirectories { return _treatsPackagesAsDirectories; }

- (void)setTreatsFilePackagesAsDirectories:(BOOL)flag
{
    _treatsPackagesAsDirectories = flag;
    if (_shown)
        [self _finchReload];
}

- (BOOL)showsHiddenFiles { return _showsHiddenFiles; }

- (void)setShowsHiddenFiles:(BOOL)flag
{
    _showsHiddenFiles = flag;
    if (_shown)
        [self _finchReload];
}

- (BOOL)showsTagField { return _showsTagField; }
- (void)setShowsTagField:(BOOL)flag { _showsTagField = flag; }
- (NSArray<NSString *> *)tagNames { return _showsTagField ? (_tagNames ?: @[]) : nil; }
- (void)setTagNames:(NSArray<NSString *> *)names { [_tagNames autorelease]; _tagNames = [names copy]; }
- (BOOL)showsContentTypes { return _showsContentTypes; }
- (void)setShowsContentTypes:(BOOL)flag { _showsContentTypes = flag; }
- (NSString *)identifier { return _identifier; }
- (void)setIdentifier:(NSString *)identifier { [_identifier autorelease]; _identifier = [identifier copy]; }
- (BOOL)isExpanded { return [self _finchIsOpenPanel]; }
- (NSView *)accessoryView { return _accessory; }

- (void)setAccessoryView:(NSView *)view
{
    [_accessory removeFromSuperview];
    [_accessory autorelease];
    _accessory = [view retain];
    if (_shown)
        [self _finchLayout];
}

- (id<NSOpenSavePanelDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSOpenSavePanelDelegate>)delegate { _delegate = delegate; }
- (void)validateVisibleColumns
{
    if (_shown)
        [self _finchReload];
}

/* Deprecated API over the same state */
- (NSString *)filename { return [[self URL] path]; }
- (NSString *)directory { return [[self directoryURL] path]; }
- (void)setDirectory:(NSString *)path { [self setDirectoryURL:path ? [NSURL fileURLWithPath:path isDirectory:YES] : nil]; }
- (NSString *)requiredFileType { return [_allowedFileTypes firstObject]; }
- (void)setRequiredFileType:(NSString *)type { [self setAllowedFileTypes:type ? @[ type ] : nil]; }

#pragma mark Views

- (void)_finchMakeViews
{
    _messageLabel = [[NSTextField wrappingLabelWithString:@""] retain];
    _nameLabel = [[NSTextField labelWithString:[self nameFieldLabel] ?: @""] retain];
    [_nameLabel setAlignment:NSTextAlignmentRight];
    _nameField = [[NSTextField textFieldWithString:@""] retain];
    [_nameField setTarget:self];
    [_nameField setAction:@selector(ok:)];
    [_nameField setDelegate:(id)self];
    _backButton = [[NSButton buttonWithTitle:@"‹" target:self action:@selector(_finchBack:)] retain];
    _pathPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 240, 24) pullsDown:NO];
    [_pathPopUp setTarget:self];
    [_pathPopUp setAction:@selector(_finchPathChosen:)];
    _newFolderButton = [[NSButton buttonWithTitle:@"New Folder" target:self action:@selector(_finchNewFolder:)] retain];
    _okButton = [[NSButton buttonWithTitle:[self prompt] target:self action:@selector(ok:)] retain];
    [_okButton setKeyEquivalent:@"\r"];
    _cancelButton = [[NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)] retain];
    [_cancelButton setKeyEquivalent:@"\033"];
    _hideExtensionButton = [[NSButton checkboxWithTitle:@"Hide extension" target:self
                                                 action:@selector(_finchToggleExtension:)] retain];
    _scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 548, 250)];
    [_scroll setHasVerticalScroller:YES];
    [_scroll setBorderType:NSLineBorder];
    _list = [[FinchFileList alloc] initWithFrame:NSMakeRect(0, 0, 548, 250)];
    _list->_panel = self;
    [_list setAutoresizingMask:NSViewWidthSizable];
    [_scroll setDocumentView:_list];
    _accessoryHolder = [[NSView alloc] initWithFrame:NSZeroRect];
}

- (void)_finchLayout
{
    BOOL open = [self _finchIsOpenPanel];
    NSView *content = [self contentView];
    for (NSView *v in [[[content subviews] copy] autorelease])
        [v removeFromSuperview];
    NSSize size = [content bounds].size;
    CGFloat W = size.width, H = size.height, y = H - 12;
    if ([self message].length) {
        NSRect r = [[self message] boundingRectWithSize:NSMakeSize(W - 32, 1000)
                                                options:NSStringDrawingUsesLineFragmentOrigin
                                             attributes:@{NSFontAttributeName : [_messageLabel font]}];
        CGFloat h = MAX(16, ceil(r.size.height));
        [_messageLabel setStringValue:[self message]];
        [_messageLabel setFrame:NSMakeRect(16, y - h, W - 32, h)];
        [_messageLabel setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
        [content addSubview:_messageLabel];
        y -= h + 8;
    }
    if (!open) {
        y -= 24;
        [_nameLabel setStringValue:[self nameFieldLabel] ?: @""];
        [_nameLabel setFrame:NSMakeRect(16, y + 3, 90, 17)];
        [_nameLabel setAutoresizingMask:NSViewMinYMargin];
        [_nameField setFrame:NSMakeRect(112, y, MIN(300, W - 128), 24)];
        [_nameField setAutoresizingMask:NSViewMinYMargin];
        [content addSubview:_nameLabel];
        [content addSubview:_nameField];
        y -= 10;
    }
    y -= 24;
    [_backButton setFrame:NSMakeRect(16, y, 32, 24)];
    [_backButton setAutoresizingMask:NSViewMinYMargin];
    [_pathPopUp setFrame:NSMakeRect(56, y, 240, 24)];
    [_pathPopUp setAutoresizingMask:NSViewMinYMargin];
    [_newFolderButton setFrame:NSMakeRect(W - 16 - 104, y, 104, 24)];
    [_newFolderButton setAutoresizingMask:NSViewMinYMargin | NSViewMinXMargin];
    [_newFolderButton setHidden:!_canCreateDirectories];
    [content addSubview:_backButton];
    [content addSubview:_pathPopUp];
    [content addSubview:_newFolderButton];
    y -= 8;
    CGFloat bottom = 16 + 24 + 12;
    if (_accessory) {
        NSRect f = [_accessory frame];
        [_accessoryHolder setFrame:NSMakeRect(16, bottom, W - 32, f.size.height)];
        [_accessoryHolder setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
        [_accessory setFrameOrigin:NSMakePoint(floor((W - 32 - f.size.width) / 2), 0)];
        [_accessory setAutoresizingMask:NSViewMinXMargin | NSViewMaxXMargin];
        [_accessoryHolder addSubview:_accessory];
        [content addSubview:_accessoryHolder];
        bottom += f.size.height + 12;
    }
    [_scroll setFrame:NSMakeRect(16, bottom, W - 32, MAX(60, y - bottom))];
    [_scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [content addSubview:_scroll];
    [_list sizeToRows];
    CGFloat okW = MAX(82, ceil([[self prompt] sizeWithAttributes:@{NSFontAttributeName : [NSFont systemFontOfSize:13]}].width) + 32);
    [_okButton setTitle:[self prompt]];
    [_okButton setFrame:NSMakeRect(W - 16 - okW, 16, okW, 24)];
    [_okButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [_cancelButton setFrame:NSMakeRect(W - 16 - okW - 12 - 82, 16, 82, 24)];
    [_cancelButton setAutoresizingMask:NSViewMinXMargin | NSViewMaxYMargin];
    [content addSubview:_cancelButton];
    [content addSubview:_okButton];
    if (!open && _canSelectHiddenExtension) {
        [_hideExtensionButton setFrame:NSMakeRect(16, 19, 160, 18)];
        [_hideExtensionButton setState:_extensionHidden ? NSControlStateValueOn : NSControlStateValueOff];
        [content addSubview:_hideExtensionButton];
    }
    [self setDefaultButtonCell:[_okButton cell]];
}

#pragma mark The directory

- (NSURL *)_finchShownDirectory
{
    NSURL *dir = [self directoryURL] ?: [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    /* a folder that isn't there shows its nearest existing ancestor */
    while (!([fm fileExistsAtPath:[dir path] isDirectory:&isDir] && isDir) && ![[dir path] isEqualToString:@"/"])
        dir = [dir URLByDeletingLastPathComponent];
    return dir;
}

- (BOOL)_finchTypeAllowed:(NSURL *)url
{
    if (!_allowedTypes.count)
        return YES;
    FinchUTTypeClass();
    UTType *t = nil;
    [url getResourceValue:&t forKey:NSURLContentTypeKey error:NULL];
    for (UTType *a in _allowedTypes)
        if (t && [t conformsToType:a])
            return YES;
    return NO;
}

- (void)_finchReload
{
    BOOL open = [self _finchIsOpenPanel];
    NSURL *dir = [self _finchShownDirectory];
    if (![[[dir URLByStandardizingPath] path] isEqualToString:[[[self directoryURL] URLByStandardizingPath] path]]) {
        [_directoryURL autorelease];
        _directoryURL = [dir retain];
        _directoryInvalid = NO;
    }
    NSArray *keys = @[ NSURLIsDirectoryKey, NSURLIsPackageKey, NSURLIsHiddenKey, NSURLIsApplicationKey ];
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dir includingPropertiesForKeys:keys
                                                                      options:0 error:NULL];
    items = [items sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [[a lastPathComponent] localizedStandardCompare:[b lastPathComponent]];
    }];
    NSMutableArray *entries = [NSMutableArray array];
    BOOL choosesFiles = !open || [(NSOpenPanel *)self canChooseFiles];
    BOOL choosesDirs = open && [(NSOpenPanel *)self canChooseDirectories];
    for (NSURL *u in items) {
        NSDictionary *v = [u resourceValuesForKeys:keys error:NULL];
        if (!_showsHiddenFiles && ([v[NSURLIsHiddenKey] boolValue] || [[u lastPathComponent] hasPrefix:@"."]))
            continue;
        BOOL isDir = [v[NSURLIsDirectoryKey] boolValue], pkg = [v[NSURLIsPackageKey] boolValue];
        FinchFileEntry *e = [[[FinchFileEntry alloc] init] autorelease];
        e->url = [u retain];
        e->name = [[u lastPathComponent] copy];
        e->directory = isDir && (!pkg || _treatsPackagesAsDirectories);
        e->icon = [v[NSURLIsApplicationKey] boolValue] ? FinchIconApplication
                  : e->directory || (isDir && !pkg)    ? FinchIconFolder
                                                       : FinchIconDocument;
        if (e->directory)
            e->enabled = YES;  /* folders open; whether one can be chosen is the prompt's business */
        else
            e->enabled = choosesFiles && [self _finchTypeAllowed:u];
        if (e->directory && choosesDirs)
            e->enabled = YES;
        if (e->enabled && [(id)_delegate respondsToSelector:@selector(panel:shouldEnableURL:)])
            e->enabled = [_delegate panel:self shouldEnableURL:u];
        [entries addObject:e];
    }
    [_list setEntries:entries];
    [self _finchUpdatePathPopUp];
    [_backButton setEnabled:_history.count > 0];
    [self _finchUpdateOK];
}

- (void)_finchUpdatePathPopUp
{
    [_pathPopUp removeAllItems];
    NSURL *u = [self directoryURL];
    for (;;) {
        NSString *p = [u path];
        NSString *title = [p isEqualToString:@"/"] ? @"/" : [p lastPathComponent];
        [_pathPopUp addItemWithTitle:title];
        [[_pathPopUp lastItem] setRepresentedObject:u];
        [[_pathPopUp lastItem] setImage:small_icon([p isEqualToString:@"/"] ? FinchIconVolume : FinchIconFolder)];
        if ([p isEqualToString:@"/"] || !p.length)
            break;
        u = [u URLByDeletingLastPathComponent];
    }
    [_pathPopUp selectItemAtIndex:0];
}

- (void)_finchGoTo:(NSURL *)dir remember:(BOOL)remember
{
    if (!dir)
        return;
    if (remember && [self directoryURL])
        [_history addObject:[self directoryURL]];
    [_directoryURL autorelease];
    _directoryURL = [dir retain];
    _directoryInvalid = NO;
    [self _finchReload];
    if ([(id)_delegate respondsToSelector:@selector(panel:didChangeToDirectoryURL:)])
        [_delegate panel:self didChangeToDirectoryURL:[self directoryURL]];
}

- (void)_finchBack:(id)sender
{
    NSURL *u = [[[_history lastObject] retain] autorelease];
    if (!u)
        return;
    [_history removeLastObject];
    [self _finchGoTo:u remember:NO];
}

- (void)_finchPathChosen:(id)sender
{
    NSURL *u = [[_pathPopUp selectedItem] representedObject];
    if (u && ![u isEqual:[self directoryURL]])
        [self _finchGoTo:u remember:YES];
}

- (void)_finchGoToEnclosingFolder
{
    NSURL *dir = [self directoryURL];
    if (dir && ![[dir path] isEqualToString:@"/"])
        [self _finchGoTo:[dir URLByDeletingLastPathComponent] remember:YES];
}

- (void)_finchNewFolder:(id)sender
{
    NSAlert *a = [[[NSAlert alloc] init] autorelease];
    [a setMessageText:@"New Folder"];
    [a setInformativeText:@"Name of new folder inside this folder:"];
    NSTextField *f = [NSTextField textFieldWithString:@"untitled folder"];
    [f setFrame:NSMakeRect(0, 0, 260, 24)];
    [a setAccessoryView:f];
    [a addButtonWithTitle:@"Create"];
    [a addButtonWithTitle:@"Cancel"];
    [a layout];
    [[a window] setInitialFirstResponder:f];
    if ([a runModal] != NSAlertFirstButtonReturn || ![f stringValue].length)
        return;
    NSURL *u = [[self directoryURL] URLByAppendingPathComponent:[f stringValue] isDirectory:YES];
    NSError *e = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:u withIntermediateDirectories:NO attributes:nil
                                                        error:&e]) {
        [[NSAlert alertWithError:e] runModal];
        return;
    }
    [self _finchGoTo:u remember:YES];
}

#pragma mark Selection and names

- (NSArray<FinchFileEntry *> *)_finchSelectedEntries
{
    NSMutableArray *a = [NSMutableArray array];
    [_list->_selection enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
        [a addObject:_list->_entries[i]];
    }];
    return a;
}

- (void)_finchSelectionChanged
{
    if (![self _finchIsOpenPanel]) {
        FinchFileEntry *e = [[self _finchSelectedEntries] firstObject];
        if (e && !e->directory) {
            [_name autorelease];
            _name = [e->name copy];
            [self _finchShowName];
        }
    }
    [self _finchUpdateOK];
    if ([(id)_delegate respondsToSelector:@selector(panelSelectionDidChange:)])
        [_delegate panelSelectionDidChange:self];
}

- (void)_finchActivateEntryAtIndex:(NSUInteger)index
{
    FinchFileEntry *e = _list->_entries[index];
    if (e->directory)
        [self _finchGoTo:e->url remember:YES];
    else if ([self _finchIsOpenPanel])
        [self ok:self];
}

/* Is a name's extension one of the allowed types'? */
- (BOOL)_finchExtensionAllowed:(NSString *)ext
{
    if (!ext.length)
        return NO;
    Class ut = FinchUTTypeClass();
    UTType *t = [ut typeWithFilenameExtension:ext];
    for (UTType *a in _allowedTypes)
        if ([t conformsToType:a])
            return YES;
    return NO;
}

/* Put _name in the field, without its extension when hidden. */
- (void)_finchShowName
{
    if (!_nameField)
        return;
    NSString *shown = _name;
    [_hiddenExtension release];
    _hiddenExtension = nil;
    NSString *ext = [_name pathExtension];
    if (_extensionHidden && ext.length && (!_allowedTypes.count || [self _finchExtensionAllowed:ext])) {
        _hiddenExtension = [ext copy];
        shown = [_name stringByDeletingPathExtension];
    }
    [_nameField setStringValue:shown ?: @""];
    [self _finchUpdateOK];
}

- (NSString *)_finchTypedName
{
    NSString *s = [_nameField stringValue] ?: @"";
    if (_hiddenExtension && s.length && ![[s pathExtension] isEqualToString:_hiddenExtension])
        s = [s stringByAppendingPathExtension:_hiddenExtension];
    return s;
}

- (void)_finchStoreTypedName
{
    [_name autorelease];
    _name = [[self _finchTypedName] copy];
}

- (void)_finchToggleExtension:(id)sender
{
    [self setExtensionHidden:[_hideExtensionButton state] == NSControlStateValueOn];
}

- (void)_finchUpdateOK
{
    BOOL ok;
    if ([self _finchIsOpenPanel]) {
        NSOpenPanel *o = (NSOpenPanel *)self;
        NSArray *sel = [self _finchSelectedEntries];
        ok = sel.count ? YES : [o canChooseDirectories];
    } else
        ok = [[_nameField stringValue] length] > 0;
    if (ok != [_okButton isEnabled]) {
        [_okButton setEnabled:ok];
        [_okButton setNeedsDisplay:YES];
    }
}

- (void)controlTextDidChange:(NSNotification *)n
{
    [self _finchUpdateOK];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)sel
{
    if (sel == @selector(cancelOperation:)) {
        [self cancel:self];
        return YES;
    }
    if (sel == @selector(insertNewline:)) {
        [self ok:self];
        return YES;
    }
    return NO;
}

#pragma mark Choosing

- (BOOL)_finchValidate:(NSURL *)url
{
    if (![(id)_delegate respondsToSelector:@selector(panel:validateURL:error:)])
        return YES;
    NSError *e = nil;
    if ([_delegate panel:self validateURL:url error:&e])
        return YES;
    if (e)
        [[NSAlert alertWithError:e] runModal];
    return NO;
}

- (NSString *)_finchNameWithExtension:(NSString *)name
{
    if (!_allowedTypes.count)
        return name;
    NSString *ext = [name pathExtension];
    if ([self _finchExtensionAllowed:ext] || (ext.length && _allowsOtherFileTypes))
        return name;
    NSString *add = [_allowedTypes[0] preferredFilenameExtension];
    return add.length ? [name stringByAppendingPathExtension:add] : name;
}

- (void)_finchFinish:(NSModalResponse)code
{
    if (_sheetParent) {
        [_sheetParent endSheet:self returnCode:code];
        return;
    }
    if (_modal) {
        [NSApp stopModalWithCode:code];
        return;
    }
    if (code != NSModalResponseOK)
        [self _finchStoreTypedName];
    [self orderOut:nil];
    _shown = NO;
    void (^h)(NSModalResponse) = _handler;
    _handler = nil;
    if (h)
        h(code);
    [h release];
}

- (IBAction)ok:(id)sender
{
    if ([self _finchIsOpenPanel]) {
        NSOpenPanel *o = (NSOpenPanel *)self;
        NSArray<FinchFileEntry *> *sel = [self _finchSelectedEntries];
        if (sel.count == 1 && sel[0]->directory && ![o canChooseDirectories]) {
            /* a folder selected where folders aren't chosen: go into it */
            [self _finchGoTo:sel[0]->url remember:YES];
            return;
        }
        NSMutableArray *urls = [NSMutableArray array];
        for (FinchFileEntry *e in sel) {
            if ((e->directory && ![o canChooseDirectories]) || (!e->directory && ![o canChooseFiles]))
                continue;
            [urls addObject:e->url];
        }
        if (!urls.count && !sel.count && [o canChooseDirectories])
            [urls addObject:[self directoryURL]];
        if (!urls.count) {
            NSBeep();
            return;
        }
        for (NSURL *u in urls)
            if (![self _finchValidate:u])
                return;
        [o _finchSetURLs:urls];
        [self _finchFinish:NSModalResponseOK];
        return;
    }
    NSString *typed = [self _finchTypedName];
    if (!typed.length) {
        NSBeep();
        return;
    }
    if ([(id)_delegate respondsToSelector:@selector(panel:userEnteredFilename:confirmed:)])
        typed = [_delegate panel:self userEnteredFilename:typed confirmed:YES] ?: typed;
    NSString *name = [self _finchNameWithExtension:typed];
    NSURL *url = [[self directoryURL] URLByAppendingPathComponent:name];
    if ([[NSFileManager defaultManager] fileExistsAtPath:[url path]]) {
        NSAlert *a = [[[NSAlert alloc] init] autorelease];
        [a setAlertStyle:NSAlertStyleCritical];
        [a setMessageText:[NSString stringWithFormat:@"“%@” already exists. Do you want to replace it?", name]];
        [a setInformativeText:[NSString stringWithFormat:@"A file or folder with the same name already exists in the "
                                                         @"folder %@. Replacing it will overwrite its current contents.",
                                                         [[self directoryURL] lastPathComponent]]];
        [a addButtonWithTitle:@"Cancel"];
        [[a addButtonWithTitle:@"Replace"] setHasDestructiveAction:YES];
        if ([a runModal] != NSAlertSecondButtonReturn)
            return;
    }
    if (![self _finchValidate:url])
        return;
    [_name autorelease];
    _name = [name copy];
    [_finalURL autorelease];
    _finalURL = [url retain];
    [self _finchFinish:NSModalResponseOK];
}

- (IBAction)cancel:(id)sender
{
    [self _finchFinish:NSModalResponseCancel];
}

- (void)cancelOperation:(id)sender
{
    [self cancel:sender];
}

#pragma mark Running

- (void)_finchPrepare
{
    [_finalURL autorelease];
    _finalURL = nil;
    [_history removeAllObjects];
    [super setTitle:[self title]];
    [self _finchLayout];
    _shown = YES;
    [self _finchReload];
    [self _finchShowName];
}

- (void)_finchFocus
{
    if ([self _finchIsOpenPanel]) {
        [self makeFirstResponder:_list];
        return;
    }
    [self makeFirstResponder:_nameField];
    NSText *editor = [_nameField currentEditor];
    NSString *shown = [_nameField stringValue];
    NSUInteger len = _hiddenExtension ? shown.length : [[shown stringByDeletingPathExtension] length];
    [editor setSelectedRange:NSMakeRange(0, len)];
}

- (NSModalResponse)runModal
{
    [self _finchPrepare];
    [self center];
    [self setLevel:NSModalPanelWindowLevel];
    [self makeKeyAndOrderFront:nil];
    [self _finchFocus];
    _modal = YES;
    NSModalResponse r = [NSApp runModalForWindow:self];
    _modal = NO;
    if (r != NSModalResponseOK)
        [self _finchStoreTypedName];  /* on OK, ok: kept the name with its extension */
    _shown = NO;
    [self orderOut:nil];
    return r;
}

- (void)beginWithCompletionHandler:(void (^)(NSModalResponse))handler
{
    [self _finchPrepare];
    [_handler release];
    _handler = [handler copy];
    [self center];
    [self setLevel:NSNormalWindowLevel];
    [self makeKeyAndOrderFront:nil];
    [self _finchFocus];
}

- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler
{
    if (!window) {
        [self beginWithCompletionHandler:handler];
        return;
    }
    [self _finchPrepare];
    [self setLevel:NSNormalWindowLevel];
    _sheetParent = window;
    void (^h)(NSModalResponse) = [[handler copy] autorelease];
    [self retain];
    [window beginSheet:self
        completionHandler:^(NSModalResponse r) {
            _sheetParent = nil;
            if (r != NSModalResponseOK)
                [self _finchStoreTypedName];
            _shown = NO;
            if (h)
                h(r);
            [self autorelease];
        }];
    [self _finchFocus];
}

- (NSInteger)runModalForDirectory:(NSString *)path file:(NSString *)filename
{
    if (path)
        [self setDirectoryURL:[NSURL fileURLWithPath:path isDirectory:YES]];
    if (filename)
        [self setNameFieldStringValue:filename];
    return [self runModal];
}

- (void)beginSheetForDirectory:(NSString *)path file:(NSString *)name modalForWindow:(NSWindow *)docWindow
                 modalDelegate:(id)delegate didEndSelector:(SEL)didEndSelector contextInfo:(void *)contextInfo
{
    if (path)
        [self setDirectoryURL:[NSURL fileURLWithPath:path isDirectory:YES]];
    if (name)
        [self setNameFieldStringValue:name];
    [self beginSheetModalForWindow:docWindow
                 completionHandler:^(NSModalResponse r) {
                     if (delegate && didEndSelector)
                         ((void (*)(id, SEL, id, NSInteger, void *))objc_msgSend)(delegate, didEndSelector, self, r,
                                                                                  contextInfo);
                 }];
}

- (IBAction)toggleShowsHiddenFiles:(id)sender { [self setShowsHiddenFiles:!_showsHiddenFiles]; }

- (BOOL)canBecomeKeyWindow { return YES; }

@end

#pragma mark - NSOpenPanel

@implementation NSOpenPanel {
    BOOL _canChooseFiles, _canChooseDirectories, _resolvesAliases, _allowsMultipleSelection;
    BOOL _accessoryDisclosed, _canDownloadUbiquitous, _canResolveUbiquitousConflicts;
    NSArray<NSURL *> *_URLs;
}

+ (NSOpenPanel *)openPanel
{
    return [[[self alloc] init] autorelease];
}

- (BOOL)_finchIsOpenPanel { return YES; }

- (instancetype)initWithContentRect:(NSRect)contentRect styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing defer:(BOOL)flag
{
    _canChooseFiles = _resolvesAliases = _canDownloadUbiquitous = _canResolveUbiquitousConflicts = YES;
    _URLs = [@[] retain];
    return [super initWithContentRect:contentRect styleMask:style backing:backing defer:flag];
}

- (void)dealloc
{
    [_URLs release];
    [super dealloc];
}

- (void)_finchSetURLs:(NSArray<NSURL *> *)urls
{
    [_URLs autorelease];
    _URLs = [urls copy];
}

- (NSArray<NSURL *> *)URLs { return _URLs; }
- (NSURL *)URL { return [_URLs firstObject]; }
- (NSString *)filename { return [[self URL] path]; }

- (NSArray *)filenames
{
    NSMutableArray *a = [NSMutableArray array];
    for (NSURL *u in _URLs)
        [a addObject:[u path]];
    return a;
}

- (BOOL)canChooseFiles { return _canChooseFiles; }
- (void)setCanChooseFiles:(BOOL)flag { _canChooseFiles = flag; [self validateVisibleColumns]; }
- (BOOL)canChooseDirectories { return _canChooseDirectories; }
- (void)setCanChooseDirectories:(BOOL)flag { _canChooseDirectories = flag; [self validateVisibleColumns]; }
- (BOOL)resolvesAliases { return _resolvesAliases; }
- (void)setResolvesAliases:(BOOL)flag { _resolvesAliases = flag; }
- (BOOL)allowsMultipleSelection { return _allowsMultipleSelection; }

- (void)setAllowsMultipleSelection:(BOOL)flag
{
    _allowsMultipleSelection = flag;
    _list->_multiple = flag;
}

- (BOOL)isAccessoryViewDisclosed { return _accessoryDisclosed; }
- (void)setAccessoryViewDisclosed:(BOOL)flag { _accessoryDisclosed = flag; }
- (BOOL)canDownloadUbiquitousContents { return _canDownloadUbiquitous; }
- (void)setCanDownloadUbiquitousContents:(BOOL)flag { _canDownloadUbiquitous = flag; }
- (BOOL)canResolveUbiquitousConflicts { return _canResolveUbiquitousConflicts; }
- (void)setCanResolveUbiquitousConflicts:(BOOL)flag { _canResolveUbiquitousConflicts = flag; }

- (NSInteger)runModalForDirectory:(NSString *)path file:(NSString *)name types:(NSArray *)fileTypes
{
    if (fileTypes)
        [self setAllowedFileTypes:fileTypes];
    return [self runModalForDirectory:path file:name];
}

- (NSInteger)runModalForTypes:(NSArray *)fileTypes
{
    return [self runModalForDirectory:nil file:nil types:fileTypes];
}

- (void)beginSheetForDirectory:(NSString *)path file:(NSString *)name types:(NSArray *)fileTypes
                modalForWindow:(NSWindow *)docWindow modalDelegate:(id)delegate didEndSelector:(SEL)didEndSelector
                   contextInfo:(void *)contextInfo
{
    if (fileTypes)
        [self setAllowedFileTypes:fileTypes];
    [self beginSheetForDirectory:path file:name modalForWindow:docWindow modalDelegate:delegate
                  didEndSelector:didEndSelector contextInfo:contextInfo];
}

- (void)beginForDirectory:(NSString *)path file:(NSString *)name types:(NSArray *)fileTypes
         modelessDelegate:(id)delegate didEndSelector:(SEL)didEndSelector contextInfo:(void *)contextInfo
{
    if (fileTypes)
        [self setAllowedFileTypes:fileTypes];
    if (path)
        [self setDirectoryURL:[NSURL fileURLWithPath:path isDirectory:YES]];
    [self beginWithCompletionHandler:^(NSModalResponse r) {
        if (delegate && didEndSelector)
            ((void (*)(id, SEL, id, NSInteger, void *))objc_msgSend)(delegate, didEndSelector, self, r, contextInfo);
    }];
}

@end
