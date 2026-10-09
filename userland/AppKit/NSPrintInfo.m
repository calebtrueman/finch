/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Printing: NSPrintInfo (a job's settings, with macOS's defaults: US
 * Letter, 72/72/90/90-point margins), NSPrinter, NSPrintOperation,
 * NSPrintPanel and NSPageLayout.
 *
 * Finch has no printing system yet. A print operation whose job
 * disposition is NSPrintSaveJob draws its view, page by page, into a PDF
 * with CoreGraphics' PDF context; spooling to a printer and previewing
 * report that there is no printer. NSView's PDF methods use the same path.
 */
#import "NSView_Finch.h"

#pragma mark - NSPrinter

@implementation NSPrinter {
    NSString *_name, *_type;
}

+ (NSArray<NSString *> *)printerNames { return @[]; }
+ (NSArray<NSString *> *)printerTypes { return @[]; }
+ (NSPrinter *)printerWithName:(NSString *)name { return nil; }
+ (NSPrinter *)printerWithType:(NSPrinterTypeName)type { return nil; }

- (NSString *)name { return _name ?: @""; }
- (NSPrinterTypeName)type { return _type ?: @""; }
- (NSInteger)languageLevel { return 0; }
- (NSSize)pageSizeForPaper:(NSPrinterPaperName)paperName { return NSZeroSize; }
- (NSDictionary<NSDeviceDescriptionKey, id> *)deviceDescription { return @{NSDeviceIsPrinter : @"YES"}; }

- (void)dealloc
{
    [_name release];
    [_type release];
    [super dealloc];
}

@end

#pragma mark - NSPrintInfo

@implementation NSPrintInfo {
    NSMutableDictionary *_dict;
}

static NSPrintInfo *shared_info;

static NSMutableDictionary *
defaults(void)
{
    return [NSMutableDictionary dictionaryWithDictionary:@{
        NSPrintBottomMargin : @90, NSPrintTopMargin : @90, NSPrintLeftMargin : @72, NSPrintRightMargin : @72,
        NSPrintCopies : @1, NSPrintDetailedErrorReporting : @NO, NSPrintFaxNumber : @"", NSPrintFirstPage : @1,
        NSPrintLastPage : @INT32_MAX, NSPrintHorizontalPagination : @(NSPrintingPaginationModeClip),
        NSPrintVerticalPagination : @(NSPrintingPaginationModeAutomatic), NSPrintHorizontallyCentered : @YES,
        NSPrintVerticallyCentered : @YES, NSPrintJobDisposition : NSPrintSpoolJob, NSPrintMustCollate : @YES,
        NSPrintOrientation : @(NSPaperOrientationPortrait), NSPrintPagesAcross : @1, NSPrintPagesDown : @1,
        NSPrintPaperName : @"na-letter", NSPrintPaperSize : [NSValue valueWithSize:NSMakeSize(612, 792)],
        NSPrintAllPages : @YES, NSPrintSelectionOnly : @NO, NSPrintScalingFactor : @1.0, NSPrintSavePath : @"",
    }];
}

+ (NSPrintInfo *)sharedPrintInfo
{
    if (!shared_info)
        shared_info = [[NSPrintInfo alloc] init];
    return shared_info;
}

+ (void)setSharedPrintInfo:(NSPrintInfo *)info
{
    [info retain];
    [shared_info release];
    shared_info = info;
}

+ (NSPrinter *)defaultPrinter { return nil; }
+ (NSString *)defaultPrinterName { return nil; }

- (instancetype)init
{
    return [self initWithDictionary:@{}];
}

- (instancetype)initWithDictionary:(NSDictionary<NSPrintInfoAttributeKey, id> *)attributes
{
    self = [super init];
    if (self) {
        _dict = [defaults() retain];
        [_dict addEntriesFromDictionary:attributes];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    NSDictionary *d = [coder allowsKeyedCoding] ? [coder decodeObjectForKey:@"NSAttributes"] : nil;
    return [self initWithDictionary:d ?: @{}];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    if ([coder allowsKeyedCoding])
        [coder encodeObject:_dict forKey:@"NSAttributes"];
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[NSPrintInfo alloc] initWithDictionary:_dict];
}

- (void)dealloc
{
    [_dict release];
    [super dealloc];
}

- (NSMutableDictionary<NSPrintInfoAttributeKey, id> *)dictionary { return _dict; }

static CGFloat num(NSPrintInfo *p, NSString *k) { return [p->_dict[k] doubleValue]; }

- (NSPrinterPaperName)paperName { return _dict[NSPrintPaperName]; }
- (void)setPaperName:(NSPrinterPaperName)name { _dict[NSPrintPaperName] = name ?: @""; }
- (NSSize)paperSize { return [_dict[NSPrintPaperSize] sizeValue]; }
- (void)setPaperSize:(NSSize)size { _dict[NSPrintPaperSize] = [NSValue valueWithSize:size]; }
- (NSPaperOrientation)orientation { return [_dict[NSPrintOrientation] integerValue]; }

/* As Apple's: the paper size swaps when the orientation does. */
- (void)setOrientation:(NSPaperOrientation)orientation
{
    if (orientation == [self orientation])
        return;
    _dict[NSPrintOrientation] = @(orientation);
    NSSize s = [self paperSize];
    BOOL wide = s.width > s.height;
    if ((orientation == NSPaperOrientationLandscape) != wide)
        [self setPaperSize:NSMakeSize(s.height, s.width)];
}

- (CGFloat)leftMargin { return num(self, NSPrintLeftMargin); }
- (void)setLeftMargin:(CGFloat)v { _dict[NSPrintLeftMargin] = @(v); }
- (CGFloat)rightMargin { return num(self, NSPrintRightMargin); }
- (void)setRightMargin:(CGFloat)v { _dict[NSPrintRightMargin] = @(v); }
- (CGFloat)topMargin { return num(self, NSPrintTopMargin); }
- (void)setTopMargin:(CGFloat)v { _dict[NSPrintTopMargin] = @(v); }
- (CGFloat)bottomMargin { return num(self, NSPrintBottomMargin); }
- (void)setBottomMargin:(CGFloat)v { _dict[NSPrintBottomMargin] = @(v); }
- (CGFloat)scalingFactor { return num(self, NSPrintScalingFactor); }
- (void)setScalingFactor:(CGFloat)v { _dict[NSPrintScalingFactor] = @(v); }
- (NSPrintingPaginationMode)horizontalPagination { return [_dict[NSPrintHorizontalPagination] integerValue]; }
- (void)setHorizontalPagination:(NSPrintingPaginationMode)m { _dict[NSPrintHorizontalPagination] = @(m); }
- (NSPrintingPaginationMode)verticalPagination { return [_dict[NSPrintVerticalPagination] integerValue]; }
- (void)setVerticalPagination:(NSPrintingPaginationMode)m { _dict[NSPrintVerticalPagination] = @(m); }
- (BOOL)isHorizontallyCentered { return [_dict[NSPrintHorizontallyCentered] boolValue]; }
- (void)setHorizontallyCentered:(BOOL)f { _dict[NSPrintHorizontallyCentered] = @(f); }
- (BOOL)isVerticallyCentered { return [_dict[NSPrintVerticallyCentered] boolValue]; }
- (void)setVerticallyCentered:(BOOL)f { _dict[NSPrintVerticallyCentered] = @(f); }
- (NSPrintJobDispositionValue)jobDisposition { return _dict[NSPrintJobDisposition]; }
- (void)setJobDisposition:(NSPrintJobDispositionValue)d { _dict[NSPrintJobDisposition] = d ?: NSPrintSpoolJob; }
- (BOOL)isSelectionOnly { return [_dict[NSPrintSelectionOnly] boolValue]; }
- (void)setSelectionOnly:(BOOL)f { _dict[NSPrintSelectionOnly] = @(f); }
- (NSPrinter *)printer { return nil; }
- (void)setPrinter:(NSPrinter *)printer {}
- (void *)PMPrintSession { return NULL; }
- (void *)PMPageFormat { return NULL; }
- (void *)PMPrintSettings { return NULL; }
- (void)updateFromPMPageFormat {}
- (void)updateFromPMPrintSettings {}
- (void)setUpPrintOperationDefaultValues {}
- (NSMutableDictionary<NSPrintInfoSettingKey, id> *)printSettings { return [NSMutableDictionary dictionary]; }
- (NSString *)localizedPaperName { return @"US Letter"; }
+ (NSString *)localizedPaperNameForPaperName:(NSPrinterPaperName)name { return name; }
- (BOOL)takesPDFFormat { return YES; }
- (NSPDFPanel *)PDFPanel { return nil; }

/* As Apple's with no printer: the paper less a small device margin. */
- (NSRect)imageablePageBounds
{
    NSSize s = [self paperSize];
    return NSMakeRect(18, 40, s.width - 36, s.height - 58);
}

@end

#pragma mark - NSPrintOperation

static NSPrintOperation *current_operation;

@implementation NSPrintOperation {
    NSView *_view;
    NSPrintInfo *_info;
    NSMutableData *_pdfData;
    NSString *_path;
    NSPrintPanel *_panel;
    NSString *_jobTitle;
    BOOL _showsPrintPanel, _showsProgressPanel, _pdfOnly;
    NSRect _insideRect;
    NSInteger _currentPage;
    NSPrintRenderingQuality _quality;
    NSPrintingPageOrder _pageOrder;
}

+ (NSPrintOperation *)printOperationWithView:(NSView *)view printInfo:(NSPrintInfo *)info
{
    NSPrintOperation *o = [[[self alloc] init] autorelease];
    o->_view = [view retain];
    o->_info = [info copy];
    o->_insideRect = [view bounds];
    o->_showsPrintPanel = YES;
    o->_showsProgressPanel = YES;
    return o;
}

+ (NSPrintOperation *)printOperationWithView:(NSView *)view
{
    return [self printOperationWithView:view printInfo:[NSPrintInfo sharedPrintInfo]];
}

+ (NSPrintOperation *)PDFOperationWithView:(NSView *)view insideRect:(NSRect)rect toData:(NSMutableData *)data
                                 printInfo:(NSPrintInfo *)info
{
    NSPrintOperation *o = [self printOperationWithView:view printInfo:info];
    o->_insideRect = rect;
    o->_pdfData = [data retain];
    o->_pdfOnly = YES;
    o->_showsPrintPanel = NO;
    o->_showsProgressPanel = NO;
    return o;
}

+ (NSPrintOperation *)PDFOperationWithView:(NSView *)view insideRect:(NSRect)rect toData:(NSMutableData *)data
{
    return [self PDFOperationWithView:view insideRect:rect toData:data printInfo:[NSPrintInfo sharedPrintInfo]];
}

+ (NSPrintOperation *)PDFOperationWithView:(NSView *)view insideRect:(NSRect)rect toPath:(NSString *)path
                                 printInfo:(NSPrintInfo *)info
{
    NSPrintOperation *o = [self PDFOperationWithView:view insideRect:rect toData:[NSMutableData data] printInfo:info];
    o->_path = [path copy];
    return o;
}

+ (NSPrintOperation *)EPSOperationWithView:(NSView *)view insideRect:(NSRect)rect toData:(NSMutableData *)data
                                 printInfo:(NSPrintInfo *)info
{
    return [self PDFOperationWithView:view insideRect:rect toData:data printInfo:info];
}

+ (NSPrintOperation *)EPSOperationWithView:(NSView *)view insideRect:(NSRect)rect toData:(NSMutableData *)data
{
    return [self PDFOperationWithView:view insideRect:rect toData:data];
}

+ (NSPrintOperation *)EPSOperationWithView:(NSView *)view insideRect:(NSRect)rect toPath:(NSString *)path
                                 printInfo:(NSPrintInfo *)info
{
    return [self PDFOperationWithView:view insideRect:rect toPath:path printInfo:info];
}

+ (NSPrintOperation *)currentOperation { return current_operation; }
+ (void)setCurrentOperation:(NSPrintOperation *)operation { current_operation = operation; }

- (void)dealloc
{
    [_view release];
    [_info release];
    [_pdfData release];
    [_path release];
    [_panel release];
    [_jobTitle release];
    [super dealloc];
}

- (NSView *)view { return _view; }
- (NSPrintInfo *)printInfo { return _info; }
- (void)setPrintInfo:(NSPrintInfo *)info { [_info autorelease]; _info = [info copy]; }
- (BOOL)isCopyingOperation { return _pdfOnly; }
- (BOOL)showsPrintPanel { return _showsPrintPanel; }
- (void)setShowsPrintPanel:(BOOL)f { _showsPrintPanel = f; }
- (BOOL)showsProgressPanel { return _showsProgressPanel; }
- (void)setShowsProgressPanel:(BOOL)f { _showsProgressPanel = f; }
- (NSString *)jobTitle { return _jobTitle; }
- (void)setJobTitle:(NSString *)t { [_jobTitle autorelease]; _jobTitle = [t copy]; }
- (NSPrintPanel *)printPanel { return _panel ?: (_panel = [[NSPrintPanel alloc] init]); }
- (void)setPrintPanel:(NSPrintPanel *)p { [_panel autorelease]; _panel = [p retain]; }
- (NSPDFPanel *)PDFPanel { return nil; }
- (void)setPDFPanel:(NSPDFPanel *)p {}
- (BOOL)canSpawnSeparateThread { return NO; }
- (void)setCanSpawnSeparateThread:(BOOL)f {}
- (NSPrintingPageOrder)pageOrder { return _pageOrder; }
- (void)setPageOrder:(NSPrintingPageOrder)o { _pageOrder = o; }
- (NSPrintRenderingQuality)preferredRenderingQuality { return _quality; }
- (NSInteger)currentPage { return _currentPage; }
- (NSRange)pageRange { return NSMakeRange(1, NSIntegerMax); }
- (NSGraphicsContext *)context { return [NSGraphicsContext currentContext]; }
- (NSGraphicsContext *)createContext { return [NSGraphicsContext currentContext]; }
- (void)destroyContext {}
- (BOOL)deliverResult { return YES; }
- (void)cleanUpOperation {}

/* The view's pages: its own (knowsPageRange:/rectForPage:), or its rect cut into page-high strips. */
static NSArray<NSValue *> *
pages(NSPrintOperation *op)
{
    NSMutableArray *rects = [NSMutableArray array];
    NSView *v = op->_view;
    NSRange range;
    if ([v knowsPageRange:&range]) {
        for (NSUInteger i = range.location; i < NSMaxRange(range) && i - range.location < 10000; i++)
            [rects addObject:[NSValue valueWithRect:[v rectForPage:(NSInteger)i]]];
        return rects;
    }
    NSPrintInfo *p = op->_info;
    NSRect r = op->_insideRect;
    CGFloat pageHeight = [p paperSize].height - [p topMargin] - [p bottomMargin];
    if (op->_pdfOnly || pageHeight <= 0 || r.size.height <= pageHeight) {
        [rects addObject:[NSValue valueWithRect:r]];
        return rects;
    }
    for (CGFloat y = 0; y < r.size.height; y += pageHeight) {
        CGFloat top = [v isFlipped] ? NSMinY(r) + y : NSMaxY(r) - y - pageHeight;
        [rects addObject:[NSValue valueWithRect:NSMakeRect(NSMinX(r), MAX(top, NSMinY(r)), r.size.width,
                                                          MIN(pageHeight, r.size.height - y))]];
    }
    return rects;
}

static BOOL
write_pdf(NSPrintOperation *op, NSURL *url, NSMutableData *data)
{
    NSArray *rects = pages(op);
    NSPrintInfo *p = op->_info;
    CGRect media = op->_pdfOnly ? NSRectToCGRect(NSMakeRect(0, 0, op->_insideRect.size.width, op->_insideRect.size.height))
                                : CGRectMake(0, 0, [p paperSize].width, [p paperSize].height);
    CGDataConsumerRef consumer = url ? CGDataConsumerCreateWithURL((CFURLRef)url)
                                     : CGDataConsumerCreateWithCFData((CFMutableDataRef)data);
    if (!consumer)
        return NO;
    CGContextRef pdf = CGPDFContextCreate(consumer, &media, NULL);
    CGDataConsumerRelease(consumer);
    if (!pdf)
        return NO;
    NSPrintOperation *saved = current_operation;
    current_operation = op;
    [op->_view beginDocument];
    NSInteger page = 1;
    for (NSValue *value in rects) {
        NSRect r = [value rectValue];
        op->_currentPage = page++;
        CGPDFContextBeginPage(pdf, NULL);
        CGContextSaveGState(pdf);
        if (!op->_pdfOnly) {
            CGFloat x = [p leftMargin], y = [p bottomMargin];
            CGFloat areaW = media.size.width - [p leftMargin] - [p rightMargin];
            CGFloat areaH = media.size.height - [p topMargin] - [p bottomMargin];
            if ([p isHorizontallyCentered])
                x += MAX(0, (areaW - r.size.width) / 2);
            if ([p isVerticallyCentered])
                y += MAX(0, (areaH - r.size.height) / 2);
            else
                y += areaH - MIN(areaH, r.size.height);
            CGContextTranslateCTM(pdf, x, y);
            CGContextScaleCTM(pdf, [p scalingFactor], [p scalingFactor]);
        }
        if ([op->_view isFlipped])
            CGContextConcatCTM(pdf, CGAffineTransformMake(1, 0, 0, -1, -NSMinX(r), NSMaxY(r)));
        else
            CGContextTranslateCTM(pdf, -NSMinX(r), -NSMinY(r));
        [op->_view beginPageInRect:r atPlacement:NSZeroPoint];
        FinchViewDrawTree(op->_view, pdf, r, YES);
        [op->_view endPage];
        CGContextRestoreGState(pdf);
        CGPDFContextEndPage(pdf);
    }
    [op->_view endDocument];
    current_operation = saved;
    CGPDFContextClose(pdf);
    CGContextRelease(pdf);
    return YES;
}

- (BOOL)runOperation
{
    if (_pdfOnly)
        return write_pdf(self, _path ? [NSURL fileURLWithPath:_path] : nil, _pdfData);
    if ([[_info jobDisposition] isEqualToString:NSPrintSaveJob]) {
        NSURL *url = [_info dictionary][NSPrintJobSavingURL];
        if (!url && [[_info dictionary][NSPrintSavePath] length])
            url = [NSURL fileURLWithPath:[_info dictionary][NSPrintSavePath]];
        return url && write_pdf(self, url, nil);
    }
    NSLog(@"Finch: no printer to print \"%@\" on", _jobTitle ?: [[_view window] title] ?: @"");
    return NO;
}

- (void)runOperationModalForWindow:(NSWindow *)docWindow delegate:(id)delegate
                    didRunSelector:(SEL)didRunSelector contextInfo:(void *)contextInfo
{
    BOOL ok = [self runOperation];
    if (delegate && didRunSelector)
        ((void (*)(id, SEL, id, BOOL, void *))objc_msgSend)(delegate, didRunSelector, self, ok, contextInfo);
}

@end

#pragma mark - Panels

@implementation NSPrintPanel {
    NSPrintPanelOptions _options;
    NSString *_helpAnchor, *_jobStyleHint;
    NSMutableArray *_accessories;
}

+ (NSPrintPanel *)printPanel { return [[[self alloc] init] autorelease]; }
- (NSPrintPanelOptions)options { return _options; }
- (void)setOptions:(NSPrintPanelOptions)o { _options = o; }
- (NSString *)helpAnchor { return _helpAnchor; }
- (void)setHelpAnchor:(NSString *)a { [_helpAnchor autorelease]; _helpAnchor = [a copy]; }
- (NSPrintPanelJobStyleHint)jobStyleHint { return _jobStyleHint; }
- (void)setJobStyleHint:(NSPrintPanelJobStyleHint)h { [_jobStyleHint autorelease]; _jobStyleHint = [h copy]; }
- (NSArray *)accessoryControllers { return _accessories ? [[_accessories copy] autorelease] : @[]; }
- (void)addAccessoryController:(NSViewController<NSPrintPanelAccessorizing> *)c
{
    if (!_accessories)
        _accessories = [[NSMutableArray alloc] init];
    [_accessories addObject:c];
}
- (void)removeAccessoryController:(NSViewController<NSPrintPanelAccessorizing> *)c
{
    [_accessories removeObjectIdenticalTo:c];
}
- (NSInteger)runModal { return NSModalResponseCancel; }
- (NSInteger)runModalWithPrintInfo:(NSPrintInfo *)info { return NSModalResponseCancel; }
- (void)beginSheetUsingPrintInfo:(NSPrintInfo *)info onWindow:(NSWindow *)window
               completionHandler:(void (^)(NSPrintPanelResult))handler
{
    if (handler)
        handler(NSPrintPanelResultCancelled);
}
- (NSPrintInfo *)printInfo { return [NSPrintInfo sharedPrintInfo]; }

- (void)dealloc
{
    [_helpAnchor release];
    [_jobStyleHint release];
    [_accessories release];
    [super dealloc];
}

@end

@implementation NSPageLayout

+ (NSPageLayout *)pageLayout { return [[[self alloc] init] autorelease]; }
- (NSInteger)runModal { return NSModalResponseCancel; }
- (NSInteger)runModalWithPrintInfo:(NSPrintInfo *)info { return NSModalResponseCancel; }
- (void)beginSheetUsingPrintInfo:(NSPrintInfo *)info onWindow:(NSWindow *)window
               completionHandler:(void (^)(NSPageLayoutResult))handler
{
    if (handler)
        handler(NSPageLayoutResultCancelled);
}
- (NSArray *)accessoryControllers { return @[]; }
- (void)addAccessoryController:(NSViewController *)c {}
- (void)removeAccessoryController:(NSViewController *)c {}
- (NSPrintInfo *)printInfo { return [NSPrintInfo sharedPrintInfo]; }

@end

#pragma mark - NSView's printing and PDF methods

@implementation NSView (FinchPrinting)

- (NSData *)dataWithPDFInsideRect:(NSRect)rect
{
    NSMutableData *d = [NSMutableData data];
    [[NSPrintOperation PDFOperationWithView:self insideRect:rect toData:d] runOperation];
    return d;
}

- (NSData *)dataWithEPSInsideRect:(NSRect)rect
{
    return [self dataWithPDFInsideRect:rect];
}

- (void)print:(id)sender
{
    [[NSPrintOperation printOperationWithView:self] runOperation];
}

- (BOOL)knowsPageRange:(NSRangePointer)range { return NO; }
- (NSRect)rectForPage:(NSInteger)page { return NSZeroRect; }
- (NSPoint)locationOfPrintRect:(NSRect)rect { return NSZeroPoint; }
- (void)beginDocument {}
- (void)endDocument {}
- (void)beginPageInRect:(NSRect)rect atPlacement:(NSPoint)location {}
- (void)endPage {}
- (NSString *)printJobTitle { return [[self window] title] ?: @""; }
- (CGFloat)heightAdjustLimit { return 0.2; }
- (CGFloat)widthAdjustLimit { return 0.2; }
- (void)adjustPageWidthNew:(CGFloat *)newRight left:(CGFloat)oldLeft right:(CGFloat)oldRight limit:(CGFloat)limit {}
- (void)adjustPageHeightNew:(CGFloat *)newBottom top:(CGFloat)oldTop bottom:(CGFloat)oldBottom limit:(CGFloat)limit {}
- (NSAttributedString *)pageHeader { return nil; }
- (NSAttributedString *)pageFooter { return nil; }

@end
