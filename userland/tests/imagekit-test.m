/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-imagekit-test: ImageCaptureCore, ICADevices and ImageKit (through
 * Quartz) as Image Capture uses them: the string constants, the classes,
 * ICDeviceBrowser browsing (on a Mac with no camera or scanner attached, as
 * Finch has none), and the defaults and properties of IKDeviceBrowserView,
 * IKCameraDeviceView and IKScannerDeviceView, without and then in a window.
 *
 * Prints everything; run it against Apple's frameworks and Finch's
 * (DYLD_FRAMEWORK_PATH) and diff all but the first line. Needs no camera or
 * scanner connected to the host.
 */
#import <AppKit/AppKit.h>
#import <ICADevices/ICADevices.h>
#import <ImageCaptureCore/ImageCaptureCore.h>
#import <Quartz/Quartz.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>

static const char *ic_names[] = {
    "ICADevicesFrameworkPath", "ICAuthorizationStatusAuthorized", "ICAuthorizationStatusDenied", "ICAuthorizationStatusNotDetermined",
    "ICAuthorizationStatusRestricted", "ICButtonTypeCopy", "ICButtonTypeMail", "ICButtonTypePrint",
    "ICButtonTypeScan", "ICButtonTypeTransfer", "ICButtonTypeWeb", "ICCameraDeviceCanAcceptPTPCommands",
    "ICCameraDeviceCanDeleteAllFiles", "ICCameraDeviceCanDeleteOneFile", "ICCameraDeviceCanReceiveFile", "ICCameraDeviceCanSyncClock",
    "ICCameraDeviceCanTakePicture", "ICCameraDeviceCanTakePictureUsingShutterReleaseOnCamera", "ICCameraDeviceSupportsApplePTP", "ICCameraDeviceSupportsHEIF",
    "ICCameraDeviceSupportsPLRUUID", "ICDeleteAfterSuccessfulDownload", "ICDeleteCanceled", "ICDeleteErrorCanceled",
    "ICDeleteErrorDeviceMissing", "ICDeleteErrorFileMissing", "ICDeleteErrorReadOnly", "ICDeleteFailed",
    "ICDeleteSuccessful", "ICDeviceCanEjectOrDisconnect", "ICDeviceLocationDescriptionBluetooth", "ICDeviceLocationDescriptionFireWire",
    "ICDeviceLocationDescriptionMassStorage", "ICDeviceLocationDescriptionUSB", "ICDownloadsDirectoryURL", "ICDownloadSidecarFiles",
    "ICEnumerationChronologicalOrder", "ICEnumerationPrioritizeSpeed", "ICEnumerationPrioritizeTethering", "ICErrorDomain",
    "ICImageSourceShouldCache", "ICImageSourceThumbnailMaxPixelSize", "ICLocalizedStatusNotificationKey", "ICMetadataBrevity",
    "ICMetadataBrevityEssential", "ICOverwrite", "ICRawExtension", "ICRunLoopMode",
    "ICSaveAsFilename", "ICSavedAncillaryFiles", "ICSavedFilename", "ICScannerStatusRequestsOverviewScan",
    "ICScannerStatusWarmingUp", "ICScannerStatusWarmUpDone", "ICStatusCodeKey", "ICStatusNotificationKey",
    "ICStatusSoftwareInstallation", "ICTransportTypeBluetooth", "ICTransportTypeExFAT", "ICTransportTypeFireWire",
    "ICTransportTypeMassStorage", "ICTransportTypeProximity", "ICTransportTypeTCPIP", "ICTransportTypeUSB",
    "ICTruncateAfterSuccessfulDownload", "ICUTTypeRaw",
};
static const char *ik_names[] = {
    "IK_ApertureBundleIdentifier", "IK_iPhotoBundleIdentifier", "IK_MailBundleIdentifier",
    "IK_PhotosBundleIdentifier", "IKAnimationDelayKey", "IKAnimationDurationKey",
    "IKAnimationFrameRateKey", "IKAnimationVelocityCurveKey", "IKCameraIrisStatusChangeNotification",
    "IKCameraStatusChangeNotification", "IKDisableFontSmothing", "IKFilterBrowserDefaultInputImage",
    "IKFilterBrowserExcludeCategories", "IKFilterBrowserExcludeFilters", "IKFilterBrowserFilterDoubleClickNotification",
    "IKFilterBrowserFilterSelectedNotification", "IKFilterBrowserShowCategories", "IKFilterBrowserShowPreview",
    "IKFilterBrowserWillPreviewFilterNotification", "IKFilterPboardType", "IKIconCellDisableTwoLineTitlesKey",
    "IKIconCellStatusProgress", "IKIconCellStatusString", "IKIconCellStatusTextAttributes",
    "IKIconCellTextSizeKey", "IKIconCellTitlesOnRightKey", "IKImageBrowserBackgroundColorKey",
    "IKImageBrowserCellBackgroundLayer", "IKImageBrowserCellForegroundLayer", "IKImageBrowserCellPlaceHolderLayer",
    "IKImageBrowserCellSelectionLayer", "IKImageBrowserCellsHighlightedTitleAttributesKey", "IKImageBrowserCellsHighlightedUnfocusedTitleAttributesKey",
    "IKImageBrowserCellsOutlineColorKey", "IKImageBrowserCellsSubtitleAttributesKey", "IKImageBrowserCellsTitleAttributesKey",
    "IKImageBrowserCGImageRepresentationType", "IKImageBrowserCGImageSourceRepresentationType", "IKImageBrowserCIImageRepresentationType",
    "IKImageBrowserDidFinishNicestRendering", "IKImageBrowserDidStabilize", "IKImageBrowserFlavorCellPartKey",
    "IKImageBrowserFlavorGridSpacingKey", "IKImageBrowserFlavorIconSizeKey", "IKImageBrowserFlavorMaxIconSizeKey",
    "IKImageBrowserFlavorShowItemInfoKey", "IKImageBrowserFlavorTextAttributesKey", "IKImageBrowserFlavorTextSizeKey",
    "IKImageBrowserFlavorTitlesOnRightKey", "IKImageBrowserGroupBackgroundColorKey", "IKImageBrowserGroupFooterLayer",
    "IKImageBrowserGroupHeaderLayer", "IKImageBrowserGroupIdentifierKey", "IKImageBrowserGroupRangeKey",
    "IKImageBrowserGroupStyleKey", "IKImageBrowserGroupTagImageKey", "IKImageBrowserGroupTitleKey",
    "IKImageBrowserIconRefPathRepresentationType", "IKImageBrowserIconRefRepresentationType", "IKImageBrowserNSBitmapImageRepresentationType",
    "IKImageBrowserNSDataRepresentationType", "IKImageBrowserNSImageRepresentationType", "IKImageBrowserNSURLRepresentationType",
    "IKImageBrowserOutlinesCellsBinding", "IKImageBrowserPathRepresentationType", "IKImageBrowserPDFPageRepresentationType",
    "IKImageBrowserPromisedRepresentationType", "IKImageBrowserQCCompositionPathRepresentationType", "IKImageBrowserQCCompositionRepresentationType",
    "IKImageBrowserQTMoviePathRepresentationType", "IKImageBrowserQTMovieRepresentationType", "IKImageBrowserQuickLookPathRepresentationType",
    "IKImageBrowserSelectionColorKey", "IKImageBrowserZoomValueBinding", "IKImageCompletedInitialLoadingNotification",
    "IKImageCompletedTileLoadNotification", "IKImageFlowSubtitleAttributesKey", "IKImageFlowTitleAttributesKey",
    "IKImageViewLoadingDidFailNotification", "IKOverlayTypeBackground", "IKOverlayTypeImage",
    "IKPictureTakerAllowsEditingKey", "IKPictureTakerAllowsFileChoosingKey", "IKPictureTakerAllowsVideoCaptureKey",
    "IKPictureTakerCropAreaSizeKey", "IKPictureTakerCustomSourcesKey", "IKPictureTakerEnableFaceDetectionKey",
    "IKPictureTakerImageTransformsKey", "IKPictureTakerInformationalTextKey", "IKPictureTakerOutputImageMaxSizeKey",
    "IKPictureTakerRemainOpenAfterValidateKey", "IKPictureTakerShowAddressBookPicture", "IKPictureTakerShowAddressBookPictureKey",
    "IKPictureTakerShowChatIconsKey", "IKPictureTakerShowEffectsKey", "IKPictureTakerShowEmptyPicture",
    "IKPictureTakerShowEmptyPictureKey", "IKPictureTakerShowRecentPictureKey", "IKPictureTakerShowUserPicturesKey",
    "IKPictureTakerSourceDefaults", "IKPictureTakerSourceKey", "IKPictureTakerSourceRecentPictures",
    "IKPictureTakerUpdateRecentPictureKey", "IKProfilePictureEditorCropSizeKey", "IKProfilePictureEditorCustomSourcesKey",
    "IKProfilePictureEditorHidePhotoStreamPictureKey", "IKProfilePictureEditorHideRecentPicturesKey", "IKProfilePictureEditorInputRectKey",
    "IKProfilePictureEditorShowAddressBookPictureKey", "IKProfilePictureEditorShowChatIconsKey", "IKProfilePictureEditorShowEmptyPictureKey",
    "IKProfilePictureEditorUpdateRecentPictureKey", "IKProfilePictureEditorViewSizeKey", "IKQuickLookContentRect",
    "IKQuickLookProperties", "IKSizeHint", "IKSlideshowAudioFile",
    "IKSlideshowModeImages", "IKSlideshowModeOther", "IKSlideshowModePDF",
    "IKSlideshowPDFDisplayBox", "IKSlideshowPDFDisplayMode", "IKSlideshowPDFDisplaysAsBook",
    "IKSlideshowScreen", "IKSlideshowStartIndex", "IKSlideshowStartPaused",
    "IKSlideshowWrapAround", "IKTaskManagerTaskDoneNotification", "IKToolModeAnnotate",
    "IKToolModeCrop", "IKToolModeMove", "IKToolModeNone",
    "IKToolModeRotate", "IKToolModeSelect", "IKToolModeSelectEllipse",
    "IKToolModeSelectLasso", "IKToolModeSelectRect", "IKToolModeSelectRectImageCapture",
    "IKUIFlavorAllowFallback", "IKUImaxSize", "IKUISizeFlavor",
    "IKUISizeMini", "IKUISizeRegular", "IKUISizeSmall",
    "kIKAllowLowPowerRendering", "kIKColorSpace", "kIKDestinationWindow",
    "kIKEnableImageSourceHardwareAcceleration", "kIKGeometryChanged", "kIKInitialBackingScale",
    "kIKInitialCenter", "kIKInitialZoomFactor", "kIKKeepZoomToFitSticky",
    "kIKOutputImageChangedNotification", "kIKPictureTakenNotification", "kIKTakePictureAbortedNotification",
    "kIKThumbnailLowResFactor", "kIKWebImageURL", "kIKWebPageURL",
    "kIKZoomToFitOnStart", "kIKZoomToFitOnStartIgnoreWindowSize",
};

static const char *classes[] = {
    "ICDeviceBrowser", "ICDevice", "ICCameraDevice", "ICScannerDevice", "ICCameraItem", "ICCameraFile",
    "ICCameraFolder", "ICScannerBandData", "ICScannerFeature", "ICScannerFeatureEnumeration",
    "ICScannerFeatureRange", "ICScannerFeatureBoolean", "ICScannerFeatureTemplate", "ICScannerFunctionalUnit",
    "ICScannerFunctionalUnitFlatbed", "ICScannerFunctionalUnitPositiveTransparency",
    "ICScannerFunctionalUnitNegativeTransparency", "ICScannerFunctionalUnitDocumentFeeder",
    "IKDeviceBrowserView", "IKCameraDeviceView", "IKScannerDeviceView",
};

/* Look the names up in the framework that has cls (other frameworks export some of the same names). */
static void
constants(const char *title, Class cls, const char **names, size_t n)
{
    printf("== %s constants\n", title);
    Dl_info info;
    dladdr((__bridge void *)cls, &info);
    void *image = dlopen(info.dli_fname, RTLD_NOLOAD);
    for (size_t i = 0; i < n; i++) {
        NSString *__unsafe_unretained *p = (NSString *__unsafe_unretained *)dlsym(image, names[i]);
        printf("%s = %s\n", names[i], p ? (*p ? [*p UTF8String] : "(nil)") : "MISSING");
    }
}

static void
spin(double seconds)
{
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

/* Spin until *flag is set, up to seconds; returns whether it was. */
static BOOL
wait_for(BOOL *flag, double seconds)
{
    for (double t = 0; t < seconds && !*flag; t += 0.05)
        spin(0.05);
    return *flag;
}

static const char *
path(NSURL *url)
{
    if (!url)
        return "(nil)";
    NSString *s = [url absoluteString];
    NSString *home = [[NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES] absoluteString];
    if ([s hasPrefix:home])
        s = [@"~/" stringByAppendingString:[s substringFromIndex:[home length]]];
    return s.UTF8String;
}

static const char *
selection(NSIndexSet *s)
{
    return s ? [[NSString stringWithFormat:@"%lu indexes", (unsigned long)s.count] UTF8String] : "nil";
}

static const char *
str(NSString *s)
{
    return s ? [[NSString stringWithFormat:@"'%@'", s] UTF8String] : "(nil)";
}

@interface BrowserDelegate : NSObject <ICDeviceBrowserDelegate> {
  @public
    BOOL _enumerated;
}
@property BOOL enumerated;
@end

/* Only devices plugged into this machine count: what's on the network differs from place to place. */
static unsigned long
usb_count(ICDeviceBrowser *b)
{
    unsigned long n = 0;
    for (ICDevice *d in b.devices)
        if ([d.transportType isEqualToString:ICTransportTypeUSB])
            n++;
    return n;
}

@implementation BrowserDelegate
- (void)deviceBrowser:(ICDeviceBrowser *)b didAddDevice:(ICDevice *)d moreComing:(BOOL)more
{
    if ([d.transportType isEqualToString:ICTransportTypeUSB])
        printf("  added %s\n", d.name.UTF8String);
}
- (void)deviceBrowser:(ICDeviceBrowser *)b didRemoveDevice:(ICDevice *)d moreGoing:(BOOL)more
{
    if ([d.transportType isEqualToString:ICTransportTypeUSB])
        printf("  removed %s\n", d.name.UTF8String);
}
- (void)deviceBrowserDidEnumerateLocalDevices:(ICDeviceBrowser *)b
{
    printf("  didEnumerateLocalDevices: browsing %d devices %lu main thread %d\n", b.isBrowsing,
           usb_count(b), [NSThread isMainThread]);
    self.enumerated = YES;
}
- (BOOL)respondsToSelector:(SEL)sel
{
    BOOL r = [super respondsToSelector:sel];
    if ([NSStringFromSelector(sel) hasPrefix:@"deviceBrowser"])
        printf("  asked %s: %d\n", sel_getName(sel), r);
    return r;
}
@end

@interface ViewDelegate : NSObject <IKDeviceBrowserViewDelegate, IKCameraDeviceViewDelegate, IKScannerDeviceViewDelegate> {
  @public
    BOOL _enumerated;
}
@property BOOL enumerated;
@end

@implementation ViewDelegate
- (void)deviceBrowserView:(IKDeviceBrowserView *)v selectionDidChange:(ICDevice *)d
{
    printf("  view selectionDidChange: %s\n", d ? d.name.UTF8String : "(nil)");
}
- (void)deviceBrowserView:(IKDeviceBrowserView *)v deviceBrowserDidEnumerateLocalDevices:(ICDeviceBrowser *)b
{
    printf("  view deviceBrowserDidEnumerateLocalDevices: browser %d same %d browsing %d devices %lu\n",
           [b isKindOfClass:[ICDeviceBrowser class]], b == [v performSelector:@selector(deviceBrowser)],
           b.isBrowsing, usb_count(b));
    self.enumerated = YES;
}
/* Device counts change as devices on the network come and go: only plugged-in ones are reported. */
- (void)deviceBrowserView:(IKDeviceBrowserView *)v numberOfDevicesChanged:(id)n
{
    if ([n isKindOfClass:[ICDeviceBrowser class]] && usb_count(n))
        printf("  view numberOfDevicesChanged: %lu\n", usb_count(n));
}
/* Each question once: the view asks again as devices come and go. */
- (BOOL)respondsToSelector:(SEL)sel
{
    static NSMutableSet *asked;
    if (!asked)
        asked = [NSMutableSet set];
    BOOL r = [super respondsToSelector:sel];
    NSString *name = NSStringFromSelector(sel);
    if ([name hasPrefix:@"deviceBrowserView"] && ![asked containsObject:name]) {
        [asked addObject:name];
        printf("  asked %s: %d\n", sel_getName(sel), r);
    }
    return r;
}
@end

static void
browser(void)
{
    printf("== ICDeviceBrowser\n");
    ICDeviceBrowser *b = [ICDeviceBrowser new];
    printf("init: browsing %d devices %s count %lu mask 0x%lx delegate %d preferred %d\n", b.isBrowsing,
           b.devices ? "array" : "nil", usb_count(b), (unsigned long)b.browsedDeviceTypeMask,
           b.delegate != nil, b.preferredDevice != nil);
    [b start];
    printf("start without delegate: browsing %d\n", b.isBrowsing);
    BrowserDelegate *d = [BrowserDelegate new];
    b.delegate = d;
    b.browsedDeviceTypeMask = ICDeviceTypeMaskCamera | ICDeviceTypeMaskScanner | ICDeviceLocationTypeMaskLocal |
                              ICDeviceLocationTypeMaskRemote;
    printf("mask 0x%lx\n", (unsigned long)b.browsedDeviceTypeMask);
    [b start];
    printf("start: browsing %d devices %lu\n", b.isBrowsing, usb_count(b));
    printf("enumerated %d\n", wait_for(&d->_enumerated, 10));
    spin(0.5);
    printf("after: browsing %d devices %lu preferred %d\n", b.isBrowsing, usb_count(b),
           b.preferredDevice != nil);
    [b stop];
    printf("stop: browsing %d devices %lu\n", b.isBrowsing, usb_count(b));
    b.browsedDeviceTypeMask = 7;
    printf("mask 7 -> 0x%lx\n", (unsigned long)b.browsedDeviceTypeMask);
    b.browsedDeviceTypeMask = 0;
    printf("mask 0 -> 0x%lx\n", (unsigned long)b.browsedDeviceTypeMask);
    b.delegate = nil;
}

static void
device_browser_view(NSView *content, ViewDelegate *d)
{
    printf("== IKDeviceBrowserView\n");
    IKDeviceBrowserView *v = [[IKDeviceBrowserView alloc] initWithFrame:NSMakeRect(0, 0, 200, 300)];
    printf("defaults: local cameras %d network cameras %d local scanners %d network scanners %d mode %ld "
           "selected %d delegate %d\n",
           v.displaysLocalCameras, v.displaysNetworkCameras, v.displaysLocalScanners, v.displaysNetworkScanners,
           (long)v.mode, v.selectedDevice != nil, v.delegate != nil);
    printf("flipped %d opaque %d intrinsic %s accessory %s initialized %s browser %d\n", v.isFlipped, v.isOpaque,
           NSStringFromSize(v.intrinsicContentSize).UTF8String,
           [[v valueForKey:@"displaysAccessoryView"] description].UTF8String,
           [[v valueForKey:@"isInitialized"] description].UTF8String,
           [v performSelector:@selector(deviceBrowser)] != nil);
    v.displaysNetworkCameras = NO;
    v.displaysLocalScanners = NO;
    v.mode = IKDeviceBrowserViewDisplayModeOutline;
    printf("set: local cameras %d network cameras %d local scanners %d network scanners %d mode %ld\n",
           v.displaysLocalCameras, v.displaysNetworkCameras, v.displaysLocalScanners, v.displaysNetworkScanners,
           (long)v.mode);
    v.displaysNetworkCameras = YES;
    v.displaysLocalScanners = YES;
    v.mode = IKDeviceBrowserViewDisplayModeTable;
    v.delegate = d;
    printf("in a window\n");
    [content addSubview:v];
    printf("enumerated %d\n", wait_for(&d->_enumerated, 10));
    spin(0.5);
    ICDeviceBrowser *b = [v performSelector:@selector(deviceBrowser)];
    printf("browser %d browsing %d devices %lu selected %d\n", b != nil, b.isBrowsing, usb_count(b),
           v.selectedDevice != nil);
    [v removeFromSuperview];
    spin(0.2);
    printf("out of the window: browser %d browsing %d\n", [v performSelector:@selector(deviceBrowser)] != nil,
           b.isBrowsing);
    v.delegate = nil;
}

static void
camera_view(NSView *content, ViewDelegate *d)
{
    printf("== IKCameraDeviceView\n");
    IKCameraDeviceView *c = [[IKCameraDeviceView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    printf("defaults: mode %ld table %d icon %d summary %s labels %s %s icon size %lu transfer %ld\n", (long)c.mode,
           c.hasDisplayModeTable, c.hasDisplayModeIcon, [[c valueForKey:@"hasDisplayModeSummary"] description].UTF8String,
           str(c.downloadAllControlLabel), str(c.downloadSelectedControlLabel), (unsigned long)c.iconSize,
           (long)c.transferMode);
    printf("downloads %d %s post-process %d %s\n", c.displaysDownloadsDirectoryControl, path(c.downloadsDirectory),
           c.displaysPostProcessApplicationControl, path(c.postProcessApplication));
    printf("can rotate %d %d delete %d download %d selection %s camera %d delegate %d intrinsic %s flipped %d\n",
           c.canRotateSelectedItemsLeft, c.canRotateSelectedItemsRight, c.canDeleteSelectedItems,
           c.canDownloadSelectedItems, selection(c.selectedIndexes), c.cameraDevice != nil, c.delegate != nil,
           NSStringFromSize(c.intrinsicContentSize).UTF8String, c.isFlipped);
    c.mode = IKCameraDeviceViewDisplayModeIcon;
    printf("mode icon -> %ld\n", (long)c.mode);
    c.mode = IKCameraDeviceViewDisplayModeNone;
    printf("mode none -> %ld\n", (long)c.mode);
    c.downloadAllControlLabel = @"Get All";
    c.downloadSelectedControlLabel = nil;
    c.transferMode = IKCameraDeviceViewTransferModeMemoryBased;
    c.displaysDownloadsDirectoryControl = YES;
    c.downloadsDirectory = [NSURL fileURLWithPath:@"/tmp" isDirectory:YES];
    c.displaysPostProcessApplicationControl = YES;
    c.postProcessApplication = nil;
    printf("set: labels %s %s transfer %ld downloads %d %s post-process %d %s\n", str(c.downloadAllControlLabel),
           str(c.downloadSelectedControlLabel), (long)c.transferMode, c.displaysDownloadsDirectoryControl,
           path(c.downloadsDirectory), c.displaysPostProcessApplicationControl, path(c.postProcessApplication));
    [c selectIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    printf("select without a camera: %s\n", selection(c.selectedIndexes));
    NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithLabels:@[ @"a", @"b" ]
                                                                trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                      target:nil action:nil];
    [c setCustomModeControl:seg];
    [c setCustomRotateControl:seg];
    [c setShowStatusInfoAsWindowSubtitle:YES];
    [c rotateLeft:nil];
    [c rotateRight:nil];
    [c deleteSelectedItems:nil];
    [c downloadSelectedItems:nil];
    [c downloadAllItems:nil];
    printf("actions without a camera: ok, segments %ld\n", (long)seg.segmentCount);
    c.delegate = d;
    [content addSubview:c];
    spin(0.3);
    printf("in a window: camera %d mode %ld selection %s\n", c.cameraDevice != nil, (long)c.mode,
           selection(c.selectedIndexes));
    [c removeFromSuperview];
    c.delegate = nil;
}

static void
scanner_view(NSView *content, ViewDelegate *d)
{
    printf("== IKScannerDeviceView\n");
    IKScannerDeviceView *s = [[IKScannerDeviceView alloc] initWithFrame:NSMakeRect(0, 0, 400, 300)];
    printf("defaults: mode %ld simple %d advanced %d transfer %ld labels %s %s document %s scanner %d delegate %d\n",
           (long)s.mode, s.hasDisplayModeSimple, s.hasDisplayModeAdvanced, (long)s.transferMode,
           str(s.scanControlLabel), str(s.overviewControlLabel), str(s.documentName), s.scannerDevice != nil,
           s.delegate != nil);
    printf("downloads %d %s post-process %d %s intrinsic %s flipped %d\n", s.displaysDownloadsDirectoryControl,
           path(s.downloadsDirectory), s.displaysPostProcessApplicationControl, path(s.postProcessApplication),
           NSStringFromSize(s.intrinsicContentSize).UTF8String, s.isFlipped);
    for (NSString *k in @[
             @"reviewSimpleScanResults", @"displaysDeviceSelectorControl", @"displaysScanSizeControl",
             @"displaysDocumentNameControl", @"displaysFileFormatControl", @"fileFormat", @"supportedFileFormats",
             @"compressionQuality", @"displaysImageCorrectionControl", @"addAutoDetectionToScanSizeControl",
             @"displaysDoneButton", @"simpleScanDocumentType", @"simpleScanOverviewResolution",
             @"simpleScanFileFormat"
         ])
        printf("  %s = %s\n", k.UTF8String, [[[s valueForKey:k] description] ?: @"(nil)" UTF8String]);
    s.mode = IKScannerDeviceViewDisplayModeSimple;
    printf("mode simple without a scanner -> %ld\n", (long)s.mode);
    s.mode = IKScannerDeviceViewDisplayModeAdvanced;
    printf("mode advanced without a scanner -> %ld\n", (long)s.mode);
    s.hasDisplayModeSimple = YES;
    s.hasDisplayModeAdvanced = YES;
    s.transferMode = IKScannerDeviceViewTransferModeMemoryBased;
    s.scanControlLabel = @"Go";
    s.overviewControlLabel = nil;
    s.documentName = @"Page";
    s.displaysDownloadsDirectoryControl = YES;
    s.downloadsDirectory = nil;
    s.displaysPostProcessApplicationControl = YES;
    [s setValue:@0.5 forKey:@"compressionQuality"];
    [s setValue:@NO forKey:@"displaysScanSizeControl"];
    [s setValue:@"public.png" forKey:@"fileFormat"];
    printf("set: simple %d advanced %d transfer %ld labels %s %s document %s downloads %d %s post-process %d "
           "quality %s scan size %s format %s mode %ld\n",
           s.hasDisplayModeSimple, s.hasDisplayModeAdvanced, (long)s.transferMode, str(s.scanControlLabel),
           str(s.overviewControlLabel), str(s.documentName), s.displaysDownloadsDirectoryControl,
           path(s.downloadsDirectory), s.displaysPostProcessApplicationControl,
           [[s valueForKey:@"compressionQuality"] description].UTF8String,
           [[s valueForKey:@"displaysScanSizeControl"] description].UTF8String,
           [[s valueForKey:@"fileFormat"] description].UTF8String, (long)s.mode);
    s.delegate = d;
    [content addSubview:s];
    spin(0.3);
    printf("in a window: scanner %d mode %ld\n", s.scannerDevice != nil, (long)s.mode);
    [s removeFromSuperview];
    s.delegate = nil;
}

int
main(void)
{
    @autoreleasepool {
        Dl_info info;
        dladdr((__bridge void *)[ICDeviceBrowser class], &info);
        printf("%s\n", info.dli_fname);
        [NSApplication sharedApplication];

        constants("ImageCaptureCore", [ICDeviceBrowser class], ic_names, sizeof ic_names / sizeof *ic_names);
        constants("ImageKit", [IKDeviceBrowserView class], ik_names, sizeof ik_names / sizeof *ik_names);
        printf("kICUTTypeRaw = %s\n", [(__bridge NSString *)kICUTTypeRaw UTF8String]);

        printf("== classes\n");
        for (size_t i = 0; i < sizeof classes / sizeof *classes; i++) {
            Class c = objc_getClass(classes[i]);
            printf("%s : %s\n", classes[i], c ? class_getName(class_getSuperclass(c)) : "MISSING");
        }
        printf("IKDeviceBrowserView conforms to IKDeviceBrowserViewDelegate %d\n",
               [IKDeviceBrowserView conformsToProtocol:@protocol(IKDeviceBrowserViewDelegate)]);

        browser();

        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 600, 400)
                                                  styleMask:NSWindowStyleMaskTitled
                                                    backing:NSBackingStoreBuffered defer:YES];
        w.releasedWhenClosed = NO;
        ViewDelegate *d = [ViewDelegate new];
        device_browser_view(w.contentView, d);
        camera_view(w.contentView, d);
        scanner_view(w.contentView, d);
        printf("done\n");
    }
    return 0;
}
