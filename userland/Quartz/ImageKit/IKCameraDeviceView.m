/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * IKCameraDeviceView: the contents of a camera, as a table or icons, with
 * import, rotate and delete controls.
 *
 * Finch has no camera support yet, so there is never a camera's contents to
 * show: the view keeps its properties as Apple's does and draws an empty list
 * (the column headings of Apple's table view over an empty background). The
 * actions do nothing without a device; the selection is nil until the view
 * has been in a window (and its list exists), then empty.
 *
 * Defaults, as Apple's (macOS 26, English): mode Table, hasDisplayModeTable
 * and hasDisplayModeIcon NO, labels "Import All" and "Import", iconSize 32,
 * file-based transfer, downloads to ~/Pictures, post-processing with Preview,
 * neither control displayed, no intrinsic size.
 *
 * The aux*Control and custom*Control setters (private and public) take the
 * window's own segmented controls and slider, as Image Capture hands its
 * toolbar's controls to the view; they are kept and left as they are.
 */
#import <Quartz/Quartz.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

NSURL *IKFinchPicturesDirectory(void);
NSURL *IKFinchPreviewApplication(void);

NSURL *
IKFinchPicturesDirectory(void)
{
    return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Pictures"] isDirectory:YES];
}

NSURL *
IKFinchPreviewApplication(void)
{
    return [NSURL fileURLWithPath:@"/System/Applications/Preview.app" isDirectory:YES];
}

@implementation IKCameraDeviceView {
    id<IKCameraDeviceViewDelegate> _ikDelegate;
    ICCameraDevice *_camera;
    IKCameraDeviceViewDisplayMode _mode;
    BOOL _hasTable, _hasIcon, _hasSummary;
    NSString *_downloadAllLabel, *_downloadSelectedLabel;
    NSUInteger _iconSize;
    IKCameraDeviceViewTransferMode _transferMode;
    BOOL _showsDownloadsDirectory, _showsPostProcess;
    NSURL *_downloadsDirectory, *_postProcess;
    NSArray *_supportedFileTypes;
    /* The window's controls the app hands over: action, delete, icon size, mode, rotate. */
    NSControl *_aux[5];
    BOOL _statusAsSubtitle, _singleSelection, _usesFilterProc;
    BOOL _installed; /* has been in a window: the (empty) list exists, with its (empty) selection */
}

enum { AUX_ACTION, AUX_DELETE, AUX_ICONSIZE, AUX_MODE, AUX_ROTATE };

- (void)commonInit
{
    _mode = IKCameraDeviceViewDisplayModeTable;
    _downloadAllLabel = [@"Import All" copy];
    _downloadSelectedLabel = [@"Import" copy];
    _iconSize = 32;
    _downloadsDirectory = [IKFinchPicturesDirectory() retain];
    _postProcess = [IKFinchPreviewApplication() retain];
}

- (void)commonInit:(id)sender
{
    [self commonInit];
}

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame]))
        [self commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super initWithCoder:coder]))
        [self commonInit];
    return self;
}

- (void)dealloc
{
    [_downloadAllLabel release];
    [_downloadSelectedLabel release];
    [_downloadsDirectory release];
    [_postProcess release];
    [_supportedFileTypes release];
    for (int i = 0; i < 5; i++)
        [_aux[i] release];
    [super dealloc];
}

- (id)valueForUndefinedKey:(NSString *)key
{
    return nil;
}

- (NSSize)intrinsicContentSize
{
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

/* Properties */

- (id<IKCameraDeviceViewDelegate>)delegate { return _ikDelegate; }
- (void)setDelegate:(id<IKCameraDeviceViewDelegate>)delegate { _ikDelegate = delegate; }
- (ICCameraDevice *)cameraDevice { return _camera; }

- (void)setCameraDevice:(ICCameraDevice *)camera
{
    _camera = camera;
    [self setNeedsDisplay:YES];
}

- (IKCameraDeviceViewDisplayMode)mode { return _mode; }

- (void)setMode:(IKCameraDeviceViewDisplayMode)mode
{
    _mode = mode;
    [self setNeedsDisplay:YES];
}

- (BOOL)hasDisplayModeTable { return _hasTable; }
- (void)setHasDisplayModeTable:(BOOL)flag { _hasTable = flag; }
- (BOOL)hasDisplayModeIcon { return _hasIcon; }
- (void)setHasDisplayModeIcon:(BOOL)flag { _hasIcon = flag; }
- (BOOL)hasDisplayModeSummary { return _hasSummary; }
- (void)setHasDisplayModeSummary:(BOOL)flag { _hasSummary = flag; }

#define COPY_PROPERTY(get, set, ivar)          \
    -(NSString *)get { return ivar; }          \
    -(void)set:(NSString *)value               \
    {                                          \
        if (value != ivar) {                   \
            [ivar release];                    \
            ivar = [value copy];               \
        }                                      \
    }
#define URL_PROPERTY(get, set, ivar)           \
    -(NSURL *)get { return ivar; }             \
    -(void)set:(NSURL *)value                  \
    {                                          \
        [value retain];                        \
        [ivar release];                        \
        ivar = value;                          \
    }

COPY_PROPERTY(downloadAllControlLabel, setDownloadAllControlLabel, _downloadAllLabel)
COPY_PROPERTY(downloadSelectedControlLabel, setDownloadSelectedControlLabel, _downloadSelectedLabel)
URL_PROPERTY(downloadsDirectory, setDownloadsDirectory, _downloadsDirectory)
URL_PROPERTY(postProcessApplication, setPostProcessApplication, _postProcess)

- (NSUInteger)iconSize { return _iconSize; }
- (void)setIconSize:(NSUInteger)size { _iconSize = size; }
- (IKCameraDeviceViewTransferMode)transferMode { return _transferMode; }
- (void)setTransferMode:(IKCameraDeviceViewTransferMode)mode { _transferMode = mode; }
- (BOOL)displaysDownloadsDirectoryControl { return _showsDownloadsDirectory; }
- (void)setDisplaysDownloadsDirectoryControl:(BOOL)flag { _showsDownloadsDirectory = flag; }
- (BOOL)displaysPostProcessApplicationControl { return _showsPostProcess; }
- (void)setDisplaysPostProcessApplicationControl:(BOOL)flag { _showsPostProcess = flag; }

- (void)setSupportedFileTypes:(NSArray *)types
{
    [types retain];
    [_supportedFileTypes release];
    _supportedFileTypes = types;
}

/* Nothing is selected without a camera's contents. */
- (BOOL)canRotateSelectedItemsLeft { return NO; }
- (BOOL)canRotateSelectedItemsRight { return NO; }
- (BOOL)canDeleteSelectedItems { return NO; }
- (BOOL)canDownloadSelectedItems { return NO; }
- (NSIndexSet *)selectedIndexes { return _installed ? [NSIndexSet indexSet] : nil; }
- (void)selectIndexes:(NSIndexSet *)indexes byExtendingSelection:(BOOL)extend { }

- (IBAction)rotateLeft:(id)sender { }
- (IBAction)rotateRight:(id)sender { }
- (IBAction)deleteSelectedItems:(id)sender { }
- (IBAction)downloadSelectedItems:(id)sender { }
- (IBAction)downloadAllItems:(id)sender { }

/* The controls the app hands over */

- (void)setAux:(int)i control:(NSControl *)control
{
    [control retain];
    [_aux[i] release];
    _aux[i] = control;
}

- (id)auxActionControl { return _aux[AUX_ACTION]; }
- (id)auxDeleteControl { return _aux[AUX_DELETE]; }
- (id)auxIconSizeControl { return _aux[AUX_ICONSIZE]; }
- (id)auxModeControl { return _aux[AUX_MODE]; }
- (id)auxRotateControl { return _aux[AUX_ROTATE]; }
- (void)setAuxActionControl:(id)c { [self setAux:AUX_ACTION control:c]; }
- (void)setAuxDeleteControl:(id)c { [self setAux:AUX_DELETE control:c]; }
- (void)setAuxIconSizeControl:(id)c { [self setAux:AUX_ICONSIZE control:c]; }
- (void)setAuxModeControl:(id)c { [self setAux:AUX_MODE control:c]; }
- (void)setAuxRotateControl:(id)c { [self setAux:AUX_ROTATE control:c]; }
- (void)setCustomActionControl:(NSSegmentedControl *)c { [self setAux:AUX_ACTION control:c]; }
- (void)setCustomDeleteControl:(NSSegmentedControl *)c { [self setAux:AUX_DELETE control:c]; }
- (void)setCustomIconSizeSlider:(NSSlider *)c { [self setAux:AUX_ICONSIZE control:c]; }
- (void)setCustomModeControl:(NSSegmentedControl *)c { [self setAux:AUX_MODE control:c]; }
- (void)setCustomRotateControl:(NSSegmentedControl *)c { [self setAux:AUX_ROTATE control:c]; }
- (void)setShowStatusInfoAsWindowSubtitle:(BOOL)flag { _statusAsSubtitle = flag; }
- (void)setAllowSingleSelectionOnly:(BOOL)flag { _singleSelection = flag; }
- (void)setUsesFilterProc:(BOOL)flag { _usesFilterProc = flag; }

- (id)objectForBinding
{
    return nil;
}

/* Apple's view also follows a device browser view's selection. */
- (void)deviceBrowserView:(IKDeviceBrowserView *)view selectionDidChange:(ICDevice *)device
{
    if (!device || ([device type] & ICDeviceTypeMaskCamera))
        [self setCameraDevice:(ICCameraDevice *)device];
}

- (void)deviceBrowserView:(IKDeviceBrowserView *)view deviceDidChangeName:(ICDevice *)device { }
- (void)deviceBrowserView:(IKDeviceBrowserView *)view deviceDidChangeSharingState:(ICDevice *)device { }

/* Drawing: an empty table under its column headings. */

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds];
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(dirty);
    if (_mode != IKCameraDeviceViewDisplayModeTable)
        return;
    const CGFloat h = 28;
    NSRect header = NSMakeRect(NSMinX(b), NSMaxY(b) - h, NSWidth(b), h);
    if (!NSIntersectsRect(header, dirty))
        return;
    [[NSColor separatorColor] setFill];
    NSRectFill(NSMakeRect(NSMinX(b), NSMinY(header), NSWidth(b), 1));
    NSDictionary *attrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName : [NSColor headerTextColor],
    };
    /* Name, Kind, Date and File Size, at the fractions of the width Apple's table gives them. */
    static const struct { const char *title; CGFloat from, to; } columns[] = {
        { "Name", 0.275, 0.477 }, { "Kind", 0.477, 0.6 }, { "Date", 0.6, 0.868 }, { "File Size", 0.868, 0.985 },
    };
    for (size_t i = 0; i < sizeof columns / sizeof *columns; i++) {
        CGFloat x = NSMinX(b) + NSWidth(b) * columns[i].from;
        NSRectFill(NSMakeRect(x, NSMinY(header) + 6, 1, h - 12));
        NSString *t = [NSString stringWithUTF8String:columns[i].title];
        NSSize s = [t sizeWithAttributes:attrs];
        [t drawAtPoint:NSMakePoint(x + 6, NSMidY(header) - s.height / 2) withAttributes:attrs];
    }
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if ([self window])
        _installed = YES;
}

- (void)drawRect_ib:(NSRect)rect
{
    [self drawRect:rect];
}

- (void)installView:(id)view
{
}

@end
