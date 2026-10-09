/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSImage: a size and a list of image reps, drawn through the best rep.
 * -lockFocus draws into a bitmap rep at the image's size (Finch's screens are
 * 1x for now). +imageNamed: finds images named with -setName:, then the main
 * bundle's asset catalog (NSAssetCatalog.m), then image files in the main
 * bundle; Apple's system images (NSImageNameCaution, ...) are Apple's artwork
 * and aren't included.
 */
#import "AppKitDrawing.h"
#import <ImageIO/ImageIO.h>

NSImageHintKey const NSImageHintCTM = @"NSImageHintCTM";
NSImageHintKey const NSImageHintInterpolation = @"NSImageHintInterpolation";
NSImageHintKey const NSImageHintUserInterfaceLayoutDirection = @"NSImageHintUserInterfaceLayoutDirection";

/* Each NSImageNameX is "NSX", as Apple's. */
NSImageName const NSImageNameActionTemplate = @"NSActionTemplate";
NSImageName const NSImageNameAddTemplate = @"NSAddTemplate";
NSImageName const NSImageNameAdvanced = @"NSAdvanced";
NSImageName const NSImageNameApplicationIcon = @"NSApplicationIcon";
NSImageName const NSImageNameBluetoothTemplate = @"NSBluetoothTemplate";
NSImageName const NSImageNameBonjour = @"NSBonjour";
NSImageName const NSImageNameBookmarksTemplate = @"NSBookmarksTemplate";
NSImageName const NSImageNameCaution = @"NSCaution";
NSImageName const NSImageNameColorPanel = @"NSColorPanel";
NSImageName const NSImageNameColumnViewTemplate = @"NSColumnViewTemplate";
NSImageName const NSImageNameComputer = @"NSComputer";
NSImageName const NSImageNameDotMac = @"NSDotMac";
NSImageName const NSImageNameEnterFullScreenTemplate = @"NSEnterFullScreenTemplate";
NSImageName const NSImageNameEveryone = @"NSEveryone";
NSImageName const NSImageNameExitFullScreenTemplate = @"NSExitFullScreenTemplate";
NSImageName const NSImageNameFlowViewTemplate = @"NSFlowViewTemplate";
NSImageName const NSImageNameFolder = @"NSFolder";
NSImageName const NSImageNameFolderBurnable = @"NSFolderBurnable";
NSImageName const NSImageNameFolderSmart = @"NSFolderSmart";
NSImageName const NSImageNameFollowLinkFreestandingTemplate = @"NSFollowLinkFreestandingTemplate";
NSImageName const NSImageNameFontPanel = @"NSFontPanel";
NSImageName const NSImageNameGoBackTemplate = @"NSGoBackTemplate";
NSImageName const NSImageNameGoForwardTemplate = @"NSGoForwardTemplate";
NSImageName const NSImageNameGoLeftTemplate = @"NSGoLeftTemplate";
NSImageName const NSImageNameGoRightTemplate = @"NSGoRightTemplate";
NSImageName const NSImageNameHomeTemplate = @"NSHomeTemplate";
NSImageName const NSImageNameIChatTheaterTemplate = @"NSIChatTheaterTemplate";
NSImageName const NSImageNameIconViewTemplate = @"NSIconViewTemplate";
NSImageName const NSImageNameInfo = @"NSInfo";
NSImageName const NSImageNameInvalidDataFreestandingTemplate = @"NSInvalidDataFreestandingTemplate";
NSImageName const NSImageNameLeftFacingTriangleTemplate = @"NSLeftFacingTriangleTemplate";
NSImageName const NSImageNameListViewTemplate = @"NSListViewTemplate";
NSImageName const NSImageNameLockLockedTemplate = @"NSLockLockedTemplate";
NSImageName const NSImageNameLockUnlockedTemplate = @"NSLockUnlockedTemplate";
NSImageName const NSImageNameMenuMixedStateTemplate = @"NSMenuMixedStateTemplate";
NSImageName const NSImageNameMenuOnStateTemplate = @"NSMenuOnStateTemplate";
NSImageName const NSImageNameMobileMe = @"NSMobileMe";
NSImageName const NSImageNameMultipleDocuments = @"NSMultipleDocuments";
NSImageName const NSImageNameNetwork = @"NSNetwork";
NSImageName const NSImageNamePathTemplate = @"NSPathTemplate";
NSImageName const NSImageNamePreferencesGeneral = @"NSPreferencesGeneral";
NSImageName const NSImageNameQuickLookTemplate = @"NSQuickLookTemplate";
NSImageName const NSImageNameRefreshFreestandingTemplate = @"NSRefreshFreestandingTemplate";
NSImageName const NSImageNameRefreshTemplate = @"NSRefreshTemplate";
NSImageName const NSImageNameRemoveTemplate = @"NSRemoveTemplate";
NSImageName const NSImageNameRevealFreestandingTemplate = @"NSRevealFreestandingTemplate";
NSImageName const NSImageNameRightFacingTriangleTemplate = @"NSRightFacingTriangleTemplate";
NSImageName const NSImageNameShareTemplate = @"NSShareTemplate";
NSImageName const NSImageNameSlideshowTemplate = @"NSSlideshowTemplate";
NSImageName const NSImageNameSmartBadgeTemplate = @"NSSmartBadgeTemplate";
NSImageName const NSImageNameStatusAvailable = @"NSStatusAvailable";
NSImageName const NSImageNameStatusNone = @"NSStatusNone";
NSImageName const NSImageNameStatusPartiallyAvailable = @"NSStatusPartiallyAvailable";
NSImageName const NSImageNameStatusUnavailable = @"NSStatusUnavailable";
NSImageName const NSImageNameStopProgressFreestandingTemplate = @"NSStopProgressFreestandingTemplate";
NSImageName const NSImageNameStopProgressTemplate = @"NSStopProgressTemplate";
NSImageName const NSImageNameTouchBarAddDetailTemplate = @"NSTouchBarAddDetailTemplate";
NSImageName const NSImageNameTouchBarAddTemplate = @"NSTouchBarAddTemplate";
NSImageName const NSImageNameTouchBarAlarmTemplate = @"NSTouchBarAlarmTemplate";
NSImageName const NSImageNameTouchBarAudioInputMuteTemplate = @"NSTouchBarAudioInputMuteTemplate";
NSImageName const NSImageNameTouchBarAudioInputTemplate = @"NSTouchBarAudioInputTemplate";
NSImageName const NSImageNameTouchBarAudioOutputMuteTemplate = @"NSTouchBarAudioOutputMuteTemplate";
NSImageName const NSImageNameTouchBarAudioOutputVolumeHighTemplate = @"NSTouchBarAudioOutputVolumeHighTemplate";
NSImageName const NSImageNameTouchBarAudioOutputVolumeLowTemplate = @"NSTouchBarAudioOutputVolumeLowTemplate";
NSImageName const NSImageNameTouchBarAudioOutputVolumeMediumTemplate = @"NSTouchBarAudioOutputVolumeMediumTemplate";
NSImageName const NSImageNameTouchBarAudioOutputVolumeOffTemplate = @"NSTouchBarAudioOutputVolumeOffTemplate";
NSImageName const NSImageNameTouchBarBookmarksTemplate = @"NSTouchBarBookmarksTemplate";
NSImageName const NSImageNameTouchBarColorPickerFill = @"NSTouchBarColorPickerFill";
NSImageName const NSImageNameTouchBarColorPickerFont = @"NSTouchBarColorPickerFont";
NSImageName const NSImageNameTouchBarColorPickerStroke = @"NSTouchBarColorPickerStroke";
NSImageName const NSImageNameTouchBarCommunicationAudioTemplate = @"NSTouchBarCommunicationAudioTemplate";
NSImageName const NSImageNameTouchBarCommunicationVideoTemplate = @"NSTouchBarCommunicationVideoTemplate";
NSImageName const NSImageNameTouchBarComposeTemplate = @"NSTouchBarComposeTemplate";
NSImageName const NSImageNameTouchBarDeleteTemplate = @"NSTouchBarDeleteTemplate";
NSImageName const NSImageNameTouchBarDownloadTemplate = @"NSTouchBarDownloadTemplate";
NSImageName const NSImageNameTouchBarEnterFullScreenTemplate = @"NSTouchBarEnterFullScreenTemplate";
NSImageName const NSImageNameTouchBarExitFullScreenTemplate = @"NSTouchBarExitFullScreenTemplate";
NSImageName const NSImageNameTouchBarFastForwardTemplate = @"NSTouchBarFastForwardTemplate";
NSImageName const NSImageNameTouchBarFolderCopyToTemplate = @"NSTouchBarFolderCopyToTemplate";
NSImageName const NSImageNameTouchBarFolderMoveToTemplate = @"NSTouchBarFolderMoveToTemplate";
NSImageName const NSImageNameTouchBarFolderTemplate = @"NSTouchBarFolderTemplate";
NSImageName const NSImageNameTouchBarGetInfoTemplate = @"NSTouchBarGetInfoTemplate";
NSImageName const NSImageNameTouchBarGoBackTemplate = @"NSTouchBarGoBackTemplate";
NSImageName const NSImageNameTouchBarGoDownTemplate = @"NSTouchBarGoDownTemplate";
NSImageName const NSImageNameTouchBarGoForwardTemplate = @"NSTouchBarGoForwardTemplate";
NSImageName const NSImageNameTouchBarGoUpTemplate = @"NSTouchBarGoUpTemplate";
NSImageName const NSImageNameTouchBarHistoryTemplate = @"NSTouchBarHistoryTemplate";
NSImageName const NSImageNameTouchBarIconViewTemplate = @"NSTouchBarIconViewTemplate";
NSImageName const NSImageNameTouchBarListViewTemplate = @"NSTouchBarListViewTemplate";
NSImageName const NSImageNameTouchBarMailTemplate = @"NSTouchBarMailTemplate";
NSImageName const NSImageNameTouchBarNewFolderTemplate = @"NSTouchBarNewFolderTemplate";
NSImageName const NSImageNameTouchBarNewMessageTemplate = @"NSTouchBarNewMessageTemplate";
NSImageName const NSImageNameTouchBarOpenInBrowserTemplate = @"NSTouchBarOpenInBrowserTemplate";
NSImageName const NSImageNameTouchBarPauseTemplate = @"NSTouchBarPauseTemplate";
NSImageName const NSImageNameTouchBarPlayheadTemplate = @"NSTouchBarPlayheadTemplate";
NSImageName const NSImageNameTouchBarPlayPauseTemplate = @"NSTouchBarPlayPauseTemplate";
NSImageName const NSImageNameTouchBarPlayTemplate = @"NSTouchBarPlayTemplate";
NSImageName const NSImageNameTouchBarQuickLookTemplate = @"NSTouchBarQuickLookTemplate";
NSImageName const NSImageNameTouchBarRecordStartTemplate = @"NSTouchBarRecordStartTemplate";
NSImageName const NSImageNameTouchBarRecordStopTemplate = @"NSTouchBarRecordStopTemplate";
NSImageName const NSImageNameTouchBarRefreshTemplate = @"NSTouchBarRefreshTemplate";
NSImageName const NSImageNameTouchBarRemoveTemplate = @"NSTouchBarRemoveTemplate";
NSImageName const NSImageNameTouchBarRewindTemplate = @"NSTouchBarRewindTemplate";
NSImageName const NSImageNameTouchBarRotateLeftTemplate = @"NSTouchBarRotateLeftTemplate";
NSImageName const NSImageNameTouchBarRotateRightTemplate = @"NSTouchBarRotateRightTemplate";
NSImageName const NSImageNameTouchBarSearchTemplate = @"NSTouchBarSearchTemplate";
NSImageName const NSImageNameTouchBarShareTemplate = @"NSTouchBarShareTemplate";
NSImageName const NSImageNameTouchBarSidebarTemplate = @"NSTouchBarSidebarTemplate";
NSImageName const NSImageNameTouchBarSkipAhead15SecondsTemplate = @"NSTouchBarSkipAhead15SecondsTemplate";
NSImageName const NSImageNameTouchBarSkipAhead30SecondsTemplate = @"NSTouchBarSkipAhead30SecondsTemplate";
NSImageName const NSImageNameTouchBarSkipAheadTemplate = @"NSTouchBarSkipAheadTemplate";
NSImageName const NSImageNameTouchBarSkipBack15SecondsTemplate = @"NSTouchBarSkipBack15SecondsTemplate";
NSImageName const NSImageNameTouchBarSkipBack30SecondsTemplate = @"NSTouchBarSkipBack30SecondsTemplate";
NSImageName const NSImageNameTouchBarSkipBackTemplate = @"NSTouchBarSkipBackTemplate";
NSImageName const NSImageNameTouchBarSkipToEndTemplate = @"NSTouchBarSkipToEndTemplate";
NSImageName const NSImageNameTouchBarSkipToStartTemplate = @"NSTouchBarSkipToStartTemplate";
NSImageName const NSImageNameTouchBarSlideshowTemplate = @"NSTouchBarSlideshowTemplate";
NSImageName const NSImageNameTouchBarTagIconTemplate = @"NSTouchBarTagIconTemplate";
NSImageName const NSImageNameTouchBarTextBoldTemplate = @"NSTouchBarTextBoldTemplate";
NSImageName const NSImageNameTouchBarTextBoxTemplate = @"NSTouchBarTextBoxTemplate";
NSImageName const NSImageNameTouchBarTextCenterAlignTemplate = @"NSTouchBarTextCenterAlignTemplate";
NSImageName const NSImageNameTouchBarTextItalicTemplate = @"NSTouchBarTextItalicTemplate";
NSImageName const NSImageNameTouchBarTextJustifiedAlignTemplate = @"NSTouchBarTextJustifiedAlignTemplate";
NSImageName const NSImageNameTouchBarTextLeftAlignTemplate = @"NSTouchBarTextLeftAlignTemplate";
NSImageName const NSImageNameTouchBarTextListTemplate = @"NSTouchBarTextListTemplate";
NSImageName const NSImageNameTouchBarTextRightAlignTemplate = @"NSTouchBarTextRightAlignTemplate";
NSImageName const NSImageNameTouchBarTextStrikethroughTemplate = @"NSTouchBarTextStrikethroughTemplate";
NSImageName const NSImageNameTouchBarTextUnderlineTemplate = @"NSTouchBarTextUnderlineTemplate";
NSImageName const NSImageNameTouchBarUserAddTemplate = @"NSTouchBarUserAddTemplate";
NSImageName const NSImageNameTouchBarUserGroupTemplate = @"NSTouchBarUserGroupTemplate";
NSImageName const NSImageNameTouchBarUserTemplate = @"NSTouchBarUserTemplate";
NSImageName const NSImageNameTouchBarVolumeDownTemplate = @"NSTouchBarVolumeDownTemplate";
NSImageName const NSImageNameTouchBarVolumeUpTemplate = @"NSTouchBarVolumeUpTemplate";
NSImageName const NSImageNameTrashEmpty = @"NSTrashEmpty";
NSImageName const NSImageNameTrashFull = @"NSTrashFull";
NSImageName const NSImageNameUser = @"NSUser";
NSImageName const NSImageNameUserAccounts = @"NSUserAccounts";
NSImageName const NSImageNameUserGroup = @"NSUserGroup";
NSImageName const NSImageNameUserGuest = @"NSUserGuest";

static NSMutableDictionary *named_images;

static NSMutableDictionary *
names(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{ named_images = [[NSMutableDictionary alloc] init]; });
    return named_images;
}

@implementation NSImage {
    NSSize _size;
    BOOL _sizeSet;
    NSMutableArray<NSImageRep *> *_reps;
    NSString *_name;
    NSColor *_backgroundColor;
    BOOL _template, _flipped, _usesEPS, _prefersColorMatch, _matchesOnMultiple, _matchesOnlyOnBestFittingAxis;
    BOOL _scalesWhenResized, _dataRetained, _cachedSeparately, _cacheDepthMatches;
    NSImageCacheMode _cacheMode;
    NSRect _alignmentRect;
    BOOL _alignmentSet;
    NSEdgeInsets _capInsets;
    NSImageResizingMode _resizingMode;
    NSString *_accessibilityDescription;
    id<NSImageDelegate> _delegate;
    /* lockFocus */
    NSBitmapImageRep *_focusRep;
    NSGraphicsContext *_focusContext;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _reps = [[NSMutableArray alloc] init];
        _prefersColorMatch = YES;
        _matchesOnMultiple = YES;
        _resizingMode = NSImageResizingModeStretch;
    }
    return self;
}

- (instancetype)initWithSize:(NSSize)size
{
    if ((self = [self init])) {
        _size = size;
        _sizeSet = YES;
    }
    return self;
}

- (instancetype)initWithData:(NSData *)data
{
    NSArray *reps = data ? [NSBitmapImageRep imageRepsWithData:data] : nil;
    if (!reps.count) {
        [self release];
        return nil;
    }
    if ((self = [self init]))
        [_reps addObjectsFromArray:reps];
    return self;
}

- (instancetype)initWithDataIgnoringOrientation:(NSData *)data { return [self initWithData:data]; }

- (instancetype)initWithContentsOfFile:(NSString *)fileName
{
    NSData *d = fileName ? [NSData dataWithContentsOfFile:fileName] : nil;
    if (!d) {
        [self release];
        return nil;
    }
    return [self initWithData:d];
}

- (instancetype)initWithContentsOfURL:(NSURL *)url
{
    NSData *d = url ? [NSData dataWithContentsOfURL:url] : nil;
    if (!d) {
        [self release];
        return nil;
    }
    return [self initWithData:d];
}

- (instancetype)initByReferencingFile:(NSString *)fileName { return [self initWithContentsOfFile:fileName]; }

- (instancetype)initByReferencingURL:(NSURL *)url
{
    NSImage *i = [self initWithContentsOfURL:url];
    return i ?: [[NSImage alloc] init];
}

- (instancetype)initWithPasteboard:(NSPasteboard *)pasteboard
{
    [self release];
    return nil;
}

- (instancetype)initWithCGImage:(CGImageRef)cgImage size:(NSSize)size
{
    if ((self = [self init])) {
        NSBitmapImageRep *r = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
        if (r) {
            if (size.width > 0 && size.height > 0)
                [r setSize:size];
            [_reps addObject:r];
            [r release];
        }
        if (size.width > 0 && size.height > 0) {
            _size = size;
            _sizeSet = YES;
        }
    }
    return self;
}

- (instancetype)initWithIconRef:(IconRef)iconRef
{
    [self release];
    return nil;
}

+ (instancetype)imageWithSize:(NSSize)size flipped:(BOOL)flipped drawingHandler:(BOOL (^)(NSRect dstRect))drawingHandler
{
    NSImage *i = [[[self alloc] initWithSize:size] autorelease];
    NSCustomImageRep *r = [[NSCustomImageRep alloc] initWithSize:size flipped:flipped drawingHandler:drawingHandler];
    [i addRepresentation:r];
    [r release];
    return i;
}

NSImage *FinchCatalogImageNamed(NSString *name, NSBundle *bundle);

+ (NSImage *)imageNamed:(NSImageName)name
{
    if (!name.length)
        return nil;
    NSMutableDictionary *n = names();
    @synchronized(n) {
        NSImage *i = n[name];
        if (i)
            return i;
    }
    NSImage *cat = FinchCatalogImageNamed(name, nil);  /* the app's asset catalog (NSAssetCatalog.m) */
    if (cat && [cat setName:name])
        return cat;
    NSBundle *b = [NSBundle mainBundle];
    NSString *path = nil;
    if ([name pathExtension].length)
        path = [b pathForResource:[name stringByDeletingPathExtension] ofType:[name pathExtension]];
    for (NSString *ext in @[ @"png", @"tiff", @"tif", @"jpg", @"jpeg", @"gif", @"bmp", @"heic", @"icns" ]) {
        if (path)
            break;
        path = [b pathForResource:name ofType:ext];
    }
    NSImage *i = path ? [[[NSImage alloc] initWithContentsOfFile:path] autorelease] : nil;
    if (i)
        [i setName:name];
    return i;
}

+ (instancetype)imageWithSystemSymbolName:(NSString *)name accessibilityDescription:(NSString *)description { return nil; }
+ (instancetype)imageWithSystemSymbolName:(NSString *)name variableValue:(double)value accessibilityDescription:(NSString *)description { return nil; }
+ (instancetype)imageWithSymbolName:(NSString *)name variableValue:(double)value { return nil; }
+ (instancetype)imageWithSymbolName:(NSString *)name bundle:(NSBundle *)bundle variableValue:(double)value { return nil; }

- (void)dealloc
{
    [_reps release];
    [_name release];
    [_backgroundColor release];
    [_accessibilityDescription release];
    [_focusRep release];
    [_focusContext release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    NSImage *i = [[NSImage alloc] init];
    i->_size = _size;
    i->_sizeSet = _sizeSet;
    for (NSImageRep *r in _reps) {
        NSImageRep *c = [r copy];
        [i->_reps addObject:c];
        [c release];
    }
    i->_backgroundColor = [_backgroundColor retain];
    i->_template = _template;
    i->_flipped = _flipped;
    i->_prefersColorMatch = _prefersColorMatch;
    i->_matchesOnMultiple = _matchesOnMultiple;
    i->_alignmentRect = _alignmentRect;
    i->_alignmentSet = _alignmentSet;
    i->_capInsets = _capInsets;
    i->_resizingMode = _resizingMode;
    i->_cacheMode = _cacheMode;
    i->_accessibilityDescription = [_accessibilityDescription copy];
    return i;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<NSImage %p Size={%g, %g} RepProvider=%@>", self, [self size].width, [self size].height,
                                      _reps.count ? _reps : nil];
}

/* MARK: Properties */

- (NSSize)size
{
    if (_sizeSet || !_reps.count)
        return _size;
    return [_reps[0] size];
}

- (void)setSize:(NSSize)size
{
    _size = size;
    _sizeSet = YES;
}

- (BOOL)setName:(NSImageName)string
{
    NSMutableDictionary *n = names();
    @synchronized(n) {
        if (string && n[string] && n[string] != self)
            return NO;
        if (_name && n[_name] == self)
            [n removeObjectForKey:_name];
        [_name release];
        _name = [string copy];
        if (string)
            n[string] = self;
    }
    return YES;
}

- (NSImageName)name { return _name; }
- (NSColor *)backgroundColor { return _backgroundColor ?: [NSColor clearColor]; }

- (void)setBackgroundColor:(NSColor *)c
{
    c = [c copy];
    [_backgroundColor release];
    _backgroundColor = c;
}

- (BOOL)usesEPSOnResolutionMismatch { return _usesEPS; }
- (void)setUsesEPSOnResolutionMismatch:(BOOL)f { _usesEPS = f; }
- (BOOL)prefersColorMatch { return _prefersColorMatch; }
- (void)setPrefersColorMatch:(BOOL)f { _prefersColorMatch = f; }
- (BOOL)matchesOnMultipleResolution { return _matchesOnMultiple; }
- (void)setMatchesOnMultipleResolution:(BOOL)f { _matchesOnMultiple = f; }
- (BOOL)matchesOnlyOnBestFittingAxis { return _matchesOnlyOnBestFittingAxis; }
- (void)setMatchesOnlyOnBestFittingAxis:(BOOL)f { _matchesOnlyOnBestFittingAxis = f; }
- (BOOL)isTemplate { return _template; }
- (void)setTemplate:(BOOL)t { _template = t; }
- (NSImageCacheMode)cacheMode { return _cacheMode; }
- (void)setCacheMode:(NSImageCacheMode)m { _cacheMode = m; }
- (NSEdgeInsets)capInsets { return _capInsets; }
- (void)setCapInsets:(NSEdgeInsets)i { _capInsets = i; }
- (NSImageResizingMode)resizingMode { return _resizingMode; }
- (void)setResizingMode:(NSImageResizingMode)m { _resizingMode = m; }
- (id<NSImageDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSImageDelegate>)d { _delegate = d; }
- (NSString *)accessibilityDescription { return _accessibilityDescription; }

- (void)setAccessibilityDescription:(NSString *)s
{
    s = [s copy];
    [_accessibilityDescription release];
    _accessibilityDescription = s;
}

- (NSRect)alignmentRect
{
    if (_alignmentSet)
        return _alignmentRect;
    NSSize s = [self size];
    return NSMakeRect(0, 0, s.width, s.height);
}

- (void)setAlignmentRect:(NSRect)r
{
    _alignmentRect = r;
    _alignmentSet = YES;
}

- (BOOL)isFlipped { return _flipped; }
- (void)setFlipped:(BOOL)flag { _flipped = flag; }
- (BOOL)scalesWhenResized { return _scalesWhenResized; }
- (void)setScalesWhenResized:(BOOL)flag { _scalesWhenResized = flag; }
- (BOOL)isDataRetained { return _dataRetained; }
- (void)setDataRetained:(BOOL)flag { _dataRetained = flag; }
- (BOOL)isCachedSeparately { return _cachedSeparately; }
- (void)setCachedSeparately:(BOOL)flag { _cachedSeparately = flag; }
- (BOOL)cacheDepthMatchesImageDepth { return _cacheDepthMatches; }
- (void)setCacheDepthMatchesImageDepth:(BOOL)flag { _cacheDepthMatches = flag; }
- (NSImageSymbolConfiguration *)symbolConfiguration { return nil; }
- (NSImage *)imageWithSymbolConfiguration:(NSImageSymbolConfiguration *)configuration { return nil; }
- (NSImage *)imageWithLocale:(NSLocale *)locale { return self; }
- (NSLocale *)locale { return nil; }

- (BOOL)isValid
{
    NSSize s = [self size];
    return _reps.count > 0 || (s.width > 0 && s.height > 0);
}

/* MARK: Representations */

- (NSArray<NSImageRep *> *)representations { return [[_reps copy] autorelease]; }
- (void)addRepresentations:(NSArray<NSImageRep *> *)imageReps { [_reps addObjectsFromArray:imageReps]; }

- (void)addRepresentation:(NSImageRep *)imageRep
{
    if (imageRep)
        [_reps addObject:imageRep];
}

- (void)removeRepresentation:(NSImageRep *)imageRep { [_reps removeObjectIdenticalTo:imageRep]; }
- (void)recache {}
- (void)cancelIncrementalLoad {}

/* The rep with the most pixels for the destination's device size, as matchesOnMultipleResolution allows. */
- (NSImageRep *)bestRepresentationForRect:(NSRect)rect context:(NSGraphicsContext *)referenceContext hints:(NSDictionary *)hints
{
    if (!_reps.count)
        return nil;
    CGFloat scale = 1;
    CGContextRef c = referenceContext.CGContext;
    if (c) {
        CGAffineTransform t = CGContextGetUserSpaceToDeviceSpaceTransform(c);
        scale = sqrt(fabs(t.a * t.d - t.b * t.c));
    }
    CGFloat want = (rect.size.width > 0 ? rect.size.width : [self size].width) * scale;
    NSImageRep *best = nil;
    CGFloat bestScore = INFINITY;
    for (NSImageRep *r in _reps) {
        CGFloat px = [r pixelsWide] > 0 ? [r pixelsWide] : [r size].width * scale;
        /* the smallest rep at least as big as needed, else the biggest */
        CGFloat score = px >= want ? px - want : 1e9 + (want - px);
        if (score < bestScore)
            best = r, bestScore = score;
    }
    return best;
}

- (NSImageRep *)bestRepresentationForDevice:(NSDictionary *)deviceDescription
{
    return [self bestRepresentationForRect:NSZeroRect context:nil hints:nil];
}

/* MARK: Drawing */

/* Apple maps the image's size onto each rep's size: fromRect is in the image's coordinates. */
static NSRect
rep_rect(NSImage *image, NSImageRep *rep, NSRect r)
{
    NSSize is = [image size], rs = [rep size];
    if (is.width <= 0 || is.height <= 0 || NSEqualSizes(is, rs))
        return r;
    CGFloat sx = rs.width / is.width, sy = rs.height / is.height;
    return NSMakeRect(r.origin.x * sx, r.origin.y * sy, r.size.width * sx, r.size.height * sy);
}

- (void)drawInRect:(NSRect)dstSpacePortionRect fromRect:(NSRect)srcSpacePortionRect operation:(NSCompositingOperation)op
          fraction:(CGFloat)requestedAlpha respectFlipped:(BOOL)respectContextIsFlipped hints:(NSDictionary *)hints
{
    NSGraphicsContext *g = [NSGraphicsContext currentContext];
    NSImageRep *rep = [self bestRepresentationForRect:dstSpacePortionRect context:g hints:hints];
    if (!rep || !g)
        return;
    NSSize s = [self size];
    NSRect src = NSIsEmptyRect(srcSpacePortionRect) ? NSMakeRect(0, 0, s.width, s.height) : srcSpacePortionRect;
    /* (a template image draws as it is; controls tint it) */
    [rep drawInRect:dstSpacePortionRect fromRect:rep_rect(self, rep, src) operation:op fraction:requestedAlpha
        respectFlipped:respectContextIsFlipped hints:hints];
}

- (void)drawInRect:(NSRect)rect fromRect:(NSRect)fromRect operation:(NSCompositingOperation)op fraction:(CGFloat)delta
{
    [self drawInRect:rect fromRect:fromRect operation:op fraction:delta respectFlipped:NO hints:nil];
}

- (void)drawAtPoint:(NSPoint)point fromRect:(NSRect)fromRect operation:(NSCompositingOperation)op fraction:(CGFloat)delta
{
    NSSize s = NSIsEmptyRect(fromRect) ? [self size] : fromRect.size;
    [self drawInRect:NSMakeRect(point.x, point.y, s.width, s.height) fromRect:fromRect operation:op fraction:delta
        respectFlipped:NO hints:nil];
}

- (void)drawInRect:(NSRect)rect
{
    [self drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
}

- (BOOL)drawRepresentation:(NSImageRep *)imageRep inRect:(NSRect)rect
{
    CGContextRef c = FinchCurrentCGContext();
    if (c && _backgroundColor && [_backgroundColor alphaComponent] > 0) {
        CGContextSaveGState(c);
        [_backgroundColor setFill];
        CGContextFillRect(c, NSRectToCGRect(rect));
        CGContextRestoreGState(c);
    }
    return [imageRep drawInRect:rect];
}

- (void)compositeToPoint:(NSPoint)point operation:(NSCompositingOperation)operation
{
    [self drawAtPoint:point fromRect:NSZeroRect operation:operation fraction:1];
}

- (void)compositeToPoint:(NSPoint)point fromRect:(NSRect)rect operation:(NSCompositingOperation)operation
{
    [self drawAtPoint:point fromRect:rect operation:operation fraction:1];
}

- (void)compositeToPoint:(NSPoint)point operation:(NSCompositingOperation)operation fraction:(CGFloat)fraction
{
    [self drawAtPoint:point fromRect:NSZeroRect operation:operation fraction:fraction];
}

- (void)compositeToPoint:(NSPoint)point fromRect:(NSRect)rect operation:(NSCompositingOperation)operation fraction:(CGFloat)fraction
{
    [self drawAtPoint:point fromRect:rect operation:operation fraction:fraction];
}

- (void)dissolveToPoint:(NSPoint)point fraction:(CGFloat)fraction
{
    [self drawAtPoint:point fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:fraction];
}

- (void)dissolveToPoint:(NSPoint)point fromRect:(NSRect)rect fraction:(CGFloat)fraction
{
    [self drawAtPoint:point fromRect:rect operation:NSCompositingOperationSourceOver fraction:fraction];
}

/* MARK: lockFocus */

- (void)lockFocusFlipped:(BOOL)flipped
{
    NSSize s = [self size];
    NSInteger w = (NSInteger)ceil(s.width), h = (NSInteger)ceil(s.height);
    if (w < 1 || h < 1)
        FinchDrawRaise(@"NSImageCacheException", @"Cannot lock focus on image %@, because it is size zero.", self);
    NSBitmapImageRep *rep = nil;
    for (NSImageRep *r in _reps)
        if ([r isKindOfClass:[NSBitmapImageRep class]] && [r pixelsWide] == w && [r pixelsHigh] == h &&
            [NSGraphicsContext graphicsContextWithBitmapImageRep:(NSBitmapImageRep *)r])
            rep = (NSBitmapImageRep *)r;
    NSGraphicsContext *g;
    if (rep) {
        g = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    } else {
        rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4
            hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0] autorelease];
        /* sRGB, as Apple's focus buffers are in the display's space */
        rep = [rep bitmapImageRepByRetaggingWithColorSpace:[NSColorSpace sRGBColorSpace]];
        [rep setSize:s];
        g = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        if (_reps.count) {
            /* what the image had becomes the starting content */
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:g];
            [self drawInRect:NSMakeRect(0, 0, s.width, s.height) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
            [NSGraphicsContext restoreGraphicsState];
        }
        [_reps removeAllObjects];
        [_reps addObject:rep];
        if (!_sizeSet) {
            _size = s;
            _sizeSet = YES;
        }
    }
    g = [NSGraphicsContext graphicsContextWithCGContext:g.CGContext flipped:flipped];
    [_focusRep release];
    _focusRep = [rep retain];
    [_focusContext release];
    _focusContext = [g retain];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:g];
    [g saveGraphicsState];
    if (flipped) {
        CGContextTranslateCTM(g.CGContext, 0, s.height);
        CGContextScaleCTM(g.CGContext, 1, -1);
    }
}

- (void)lockFocus { [self lockFocusFlipped:NO]; }

- (void)lockFocusOnRepresentation:(NSImageRep *)imageRepresentation { [self lockFocus]; }

- (void)unlockFocus
{
    if (!_focusContext)
        return;
    [_focusContext restoreGraphicsState];
    [_focusContext flushGraphics];
    [NSGraphicsContext restoreGraphicsState];
    [_focusRep _finchInvalidateImage];
    [_focusContext release];
    _focusContext = nil;
    [_focusRep release];
    _focusRep = nil;
}

/* MARK: CGImage */

- (CGImageRef)CGImageForProposedRect:(NSRect *)proposedDestRect context:(NSGraphicsContext *)referenceContext hints:(NSDictionary *)hints
{
    NSSize s = [self size];
    NSRect r = proposedDestRect ? *proposedDestRect : NSMakeRect(0, 0, s.width, s.height);
    NSImageRep *rep = [self bestRepresentationForRect:r context:referenceContext hints:hints];
    if (!rep)
        return NULL;
    if ([rep isKindOfClass:[NSBitmapImageRep class]])
        return [(NSBitmapImageRep *)rep CGImage];
    {
        CGFloat scale = 1;
        if (referenceContext.CGContext) {
            CGAffineTransform t = CGContextGetUserSpaceToDeviceSpaceTransform(referenceContext.CGContext);
            scale = fmax(1, sqrt(fabs(t.a * t.d - t.b * t.c)));
        }
        size_t w = (size_t)ceil(r.size.width * scale), h = (size_t)ceil(r.size.height * scale);
        if (!w || !h)
            return NULL;
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef bc = CGBitmapContextCreate(NULL, w, h, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(cs);
        NSGraphicsContext *g = [NSGraphicsContext graphicsContextWithCGContext:bc flipped:NO];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:g];
        CGContextScaleCTM(bc, scale, scale);
        [self drawInRect:NSMakeRect(0, 0, r.size.width, r.size.height) fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver fraction:1];
        [NSGraphicsContext restoreGraphicsState];
        CGImageRef im = CGBitmapContextCreateImage(bc);
        CGContextRelease(bc);
        return (CGImageRef)[(id)im autorelease];
    }
    return NULL;
}

- (CGImageRef)_finchCGImage
{
    return [self CGImageForProposedRect:NULL context:nil hints:nil];
}

- (BOOL)hitTestRect:(NSRect)testRectDestSpace withImageDestinationRect:(NSRect)imageRectDestSpace context:(NSGraphicsContext *)context
              hints:(NSDictionary *)hints flipped:(BOOL)flipped
{
    NSRect hit = NSIntersectionRect(testRectDestSpace, imageRectDestSpace);
    if (NSIsEmptyRect(hit))
        return NO;
    CGImageRef im = [self _finchCGImage];
    if (!im)
        return YES;
    /* any pixel under the rect with some alpha */
    NSBitmapImageRep *r = [[[NSBitmapImageRep alloc] initWithCGImage:im] autorelease];
    CGFloat sx = [r pixelsWide] / imageRectDestSpace.size.width, sy = [r pixelsHigh] / imageRectDestSpace.size.height;
    for (CGFloat y = NSMinY(hit); y < NSMaxY(hit); y += 1 / sy)
        for (CGFloat x = NSMinX(hit); x < NSMaxX(hit); x += 1 / sx) {
            NSInteger px = (NSInteger)((x - NSMinX(imageRectDestSpace)) * sx);
            CGFloat fy = (y - NSMinY(imageRectDestSpace)) * sy;
            NSInteger py = flipped ? (NSInteger)fy : [r pixelsHigh] - 1 - (NSInteger)fy;
            if ([[r colorAtX:px y:py] alphaComponent] > 0)
                return YES;
        }
    return NO;
}

- (CGFloat)recommendedLayerContentsScale:(CGFloat)preferredContentsScale
{
    return preferredContentsScale > 0 ? preferredContentsScale : 1;
}

- (id)layerContentsForContentsScale:(CGFloat)layerContentsScale
{
    return (id)[self _finchCGImage];
}

/* MARK: Data */

- (NSData *)TIFFRepresentation
{
    return [self TIFFRepresentationUsingCompression:NSTIFFCompressionNone factor:0];
}

- (NSData *)TIFFRepresentationUsingCompression:(NSTIFFCompression)comp factor:(float)factor
{
    NSMutableArray *bitmaps = [NSMutableArray array];
    for (NSImageRep *r in _reps) {
        if ([r isKindOfClass:[NSBitmapImageRep class]])
            [bitmaps addObject:r];
        else {
            CGImageRef im = [r CGImageForProposedRect:NULL context:nil hints:nil];
            NSBitmapImageRep *b = im ? [[[NSBitmapImageRep alloc] initWithCGImage:im] autorelease] : nil;
            if (b)
                [bitmaps addObject:b];
        }
    }
    return [NSBitmapImageRep TIFFRepresentationOfImageRepsInArray:bitmaps usingCompression:comp factor:factor];
}

+ (NSArray<NSString *> *)imageTypes { return [NSImageRep imageTypes]; }
+ (NSArray<NSString *> *)imageUnfilteredTypes { return [NSImageRep imageUnfilteredTypes]; }
+ (NSArray<NSString *> *)imageFileTypes { return [NSImageRep imageFileTypes]; }
+ (NSArray<NSString *> *)imageUnfilteredFileTypes { return [NSImageRep imageUnfilteredFileTypes]; }
+ (NSArray<NSPasteboardType> *)imagePasteboardTypes { return [NSImageRep imageTypes]; }
+ (NSArray<NSPasteboardType> *)imageUnfilteredPasteboardTypes { return [NSImageRep imageUnfilteredTypes]; }
+ (BOOL)canInitWithPasteboard:(NSPasteboard *)pasteboard { return NO; }

/* MARK: NSCoding (Apple's keys: NSSize, NSReps, NSImageFlags-less) */

+ (BOOL)supportsSecureCoding { return YES; }

- (void)encodeWithCoder:(NSCoder *)coder
{
    if (![coder allowsKeyedCoding])
        return;
    if (_name && named_images[_name] == self) {
        [coder encodeObject:_name forKey:@"NSName"];
        return;
    }
    [coder encodeSize:[self size] forKey:@"NSSize"];
    NSMutableArray *reps = [NSMutableArray array];
    for (NSImageRep *r in _reps)
        if ([r conformsToProtocol:@protocol(NSCoding)])
            [reps addObject:r];
    [coder encodeObject:reps forKey:@"NSReps"];
    if (_template)
        [coder encodeBool:YES forKey:@"NSTemplate"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSString *name = [coder decodeObjectOfClass:[NSString class] forKey:@"NSName"];
    if (name) {
        [self release];
        return [[NSImage imageNamed:name] retain];
    }
    if ((self = [self init])) {
        if ([coder containsValueForKey:@"NSSize"]) {
            _size = [coder decodeSizeForKey:@"NSSize"];
            _sizeSet = YES;
        }
        NSSet *classes = [NSSet setWithObjects:[NSArray class], [NSBitmapImageRep class], [NSImageRep class], nil];
        NSArray *reps = [coder decodeObjectOfClasses:classes forKey:@"NSReps"];
        for (id r in reps)
            if ([r isKindOfClass:[NSImageRep class]])
                [_reps addObject:r];
        _template = [coder decodeBoolForKey:@"NSTemplate"];
    }
    return self;
}

@end
