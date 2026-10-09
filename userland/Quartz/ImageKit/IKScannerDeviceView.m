/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * IKScannerDeviceView: a scanner's controls (simple and advanced modes) and
 * its overview.
 *
 * Finch has no scanner support yet. Without a scanner Apple's view shows
 * nothing and its mode stays None (setMode: is ignored until a scanner is
 * set); Finch's does the same and keeps the properties as Apple's does.
 *
 * Defaults, as Apple's (macOS 26, English): mode None, neither display mode,
 * file-based transfer, labels "Scan" and "Overview", document name "Scan",
 * downloads to ~/Pictures, post-processing with Preview, and the private
 * scan-panel options (scan size, document name, file format and image
 * correction controls shown, auto-detection in the scan size control,
 * compression quality 0.8).
 */
#import <Quartz/Quartz.h>

NSURL *IKFinchPicturesDirectory(void);
NSURL *IKFinchPreviewApplication(void);

@implementation IKScannerDeviceView {
    id<IKScannerDeviceViewDelegate> _ikDelegate;
    ICScannerDevice *_scanner;
    IKScannerDeviceViewDisplayMode _mode;
    BOOL _hasSimple, _hasAdvanced;
    IKScannerDeviceViewTransferMode _transferMode;
    NSString *_scanLabel, *_overviewLabel, *_documentName, *_fileFormat, *_simpleFileFormat;
    BOOL _showsDownloadsDirectory, _showsPostProcess;
    NSURL *_downloadsDirectory, *_postProcess;
    BOOL _reviewSimple, _showsDeviceSelector, _showsScanSize, _showsDocumentName, _showsFileFormat;
    BOOL _showsImageCorrection, _autoDetection, _showsDone;
    double _compressionQuality;
    NSUInteger _simpleDocumentType, _simpleOverviewResolution;
}

- (void)commonInit
{
    _mode = IKScannerDeviceViewDisplayModeNone;
    _scanLabel = [@"Scan" copy];
    _overviewLabel = [@"Overview" copy];
    _documentName = [@"Scan" copy];
    _downloadsDirectory = [IKFinchPicturesDirectory() retain];
    _postProcess = [IKFinchPreviewApplication() retain];
    _showsScanSize = _showsDocumentName = _showsFileFormat = _showsImageCorrection = _autoDetection = YES;
    _compressionQuality = 0.8;
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
    [_scanLabel release];
    [_overviewLabel release];
    [_documentName release];
    [_fileFormat release];
    [_simpleFileFormat release];
    [_downloadsDirectory release];
    [_postProcess release];
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

- (id<IKScannerDeviceViewDelegate>)delegate { return _ikDelegate; }
- (void)setDelegate:(id<IKScannerDeviceViewDelegate>)delegate { _ikDelegate = delegate; }
- (ICScannerDevice *)scannerDevice { return _scanner; }

- (void)setScannerDevice:(ICScannerDevice *)scanner
{
    _scanner = scanner;
    if (!scanner)
        _mode = IKScannerDeviceViewDisplayModeNone;
    [self setNeedsDisplay:YES];
}

- (IKScannerDeviceViewDisplayMode)mode { return _mode; }

- (void)setMode:(IKScannerDeviceViewDisplayMode)mode
{
    if (!_scanner)
        return;
    _mode = mode;
    [self setNeedsDisplay:YES];
}

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
#define BOOL_PROPERTY(get, set, ivar)          \
    -(BOOL)get { return ivar; }                \
    -(void)set:(BOOL)value { ivar = value; }

COPY_PROPERTY(scanControlLabel, setScanControlLabel, _scanLabel)
COPY_PROPERTY(documentName, setDocumentName, _documentName)
COPY_PROPERTY(fileFormat, setFileFormat, _fileFormat)
COPY_PROPERTY(simpleScanFileFormat, setSimpleScanFileFormat, _simpleFileFormat)
URL_PROPERTY(downloadsDirectory, setDownloadsDirectory, _downloadsDirectory)
URL_PROPERTY(postProcessApplication, setPostProcessApplication, _postProcess)
BOOL_PROPERTY(hasDisplayModeSimple, setHasDisplayModeSimple, _hasSimple)
BOOL_PROPERTY(hasDisplayModeAdvanced, setHasDisplayModeAdvanced, _hasAdvanced)
BOOL_PROPERTY(displaysDownloadsDirectoryControl, setDisplaysDownloadsDirectoryControl, _showsDownloadsDirectory)
BOOL_PROPERTY(displaysPostProcessApplicationControl, setDisplaysPostProcessApplicationControl, _showsPostProcess)
BOOL_PROPERTY(reviewSimpleScanResults, setReviewSimpleScanResults, _reviewSimple)
BOOL_PROPERTY(displaysDeviceSelectorControl, setDisplaysDeviceSelectorControl, _showsDeviceSelector)
BOOL_PROPERTY(displaysScanSizeControl, setDisplaysScanSizeControl, _showsScanSize)
BOOL_PROPERTY(displaysDocumentNameControl, setDisplaysDocumentNameControl, _showsDocumentName)
BOOL_PROPERTY(displaysFileFormatControl, setDisplaysFileFormatControl, _showsFileFormat)
BOOL_PROPERTY(displaysImageCorrectionControl, setDisplaysImageCorrectionControl, _showsImageCorrection)
BOOL_PROPERTY(addAutoDetectionToScanSizeControl, setAddAutoDetectionToScanSizeControl, _autoDetection)
BOOL_PROPERTY(displaysDoneButton, setDisplaysDoneButton, _showsDone)

/* Unlike the others, the overview label goes back to its default when set to nil. */
- (NSString *)overviewControlLabel
{
    return _overviewLabel ?: @"Overview";
}

- (void)setOverviewControlLabel:(NSString *)label
{
    if (label != _overviewLabel) {
        [_overviewLabel release];
        _overviewLabel = [label copy];
    }
}

- (IKScannerDeviceViewTransferMode)transferMode { return _transferMode; }
- (void)setTransferMode:(IKScannerDeviceViewTransferMode)mode { _transferMode = mode; }
- (double)compressionQuality { return _compressionQuality; }
- (void)setCompressionQuality:(double)q { _compressionQuality = q; }
- (NSUInteger)simpleScanDocumentType { return _simpleDocumentType; }
- (void)setSimpleScanDocumentType:(NSUInteger)t { _simpleDocumentType = t; }
- (NSUInteger)simpleScanOverviewResolution { return _simpleOverviewResolution; }
- (void)setSimpleScanOverviewResolution:(NSUInteger)r { _simpleOverviewResolution = r; }

/* The formats a scan can be saved in come from the scanner. */
- (NSArray *)supportedFileFormats
{
    return nil;
}

- (void)deviceBrowserView:(IKDeviceBrowserView *)view selectionDidChange:(ICDevice *)device
{
    if (!device || ([device type] & ICDeviceTypeMaskScanner))
        [self setScannerDevice:(ICScannerDevice *)device];
}

- (void)deviceBrowserView:(IKDeviceBrowserView *)view deviceDidChangeName:(ICDevice *)device { }
- (void)deviceBrowserView:(IKDeviceBrowserView *)view deviceDidChangeSharingState:(ICDevice *)device { }

- (void)drawRect_ib:(NSRect)rect
{
}

- (void)installView:(id)view
{
}

@end
