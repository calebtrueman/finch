/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * IKDeviceBrowserView: the list of cameras and scanners an app such as Image
 * Capture shows in its sidebar.
 *
 * Like Apple's, the view runs its own ICDeviceBrowser once it is in a window
 * (and keeping it running when the view leaves the window), browsing the kinds of device its displays*
 * properties ask for, and passes the browser's news to its delegate:
 * deviceBrowserView:deviceBrowserDidEnumerateLocalDevices: (private, asked for
 * with respondsToSelector:), deviceBrowserView:numberOfDevicesChanged: and
 * deviceBrowserView:selectionDidChange:.
 *
 * Apple's is a source-list NSTableView with "DEVICES" and "SHARED" group rows;
 * Finch's draws the same headings itself, with a "No Devices" placeholder row
 * (Finch has no camera or scanner support yet, so the list stays empty), and
 * lists any devices by name with selection by click.
 *
 * Defaults, as Apple's: all four displays* YES, mode Table, no selection,
 * displaysAccessoryView NO, no intrinsic size, not flipped, not opaque.
 */
#import <Quartz/Quartz.h>

@interface IKDeviceBrowserView () <ICDeviceBrowserDelegate>
@end

@interface NSObject (IKDeviceBrowserViewDelegatePrivate)
- (void)deviceBrowserView:(IKDeviceBrowserView *)view deviceBrowserDidEnumerateLocalDevices:(ICDeviceBrowser *)browser;
- (void)deviceBrowserView:(IKDeviceBrowserView *)view numberOfDevicesChanged:(NSNumber *)count;
@end

static const CGFloat kHeaderHeight = 29, kRowHeight = 30, kInset = 16;

@implementation IKDeviceBrowserView {
    id<IKDeviceBrowserViewDelegate> _ikDelegate;
    BOOL _localCameras, _networkCameras, _localScanners, _networkScanners;
    BOOL _accessoryView, _initialized;
    IKDeviceBrowserViewDisplayMode _mode;
    ICDeviceBrowser *_browser;
    NSMutableArray *_shown; /* the devices listed, in the order found */
    ICDevice *_selected;
}

- (void)commonInit
{
    _localCameras = _networkCameras = _localScanners = _networkScanners = YES;
    _mode = IKDeviceBrowserViewDisplayModeTable;
    _shown = [NSMutableArray new];
    _initialized = YES;
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
    [_browser setDelegate:nil];
    [_browser stop];
    [_browser release];
    [_shown release];
    [_selected release];
    [super dealloc];
}

- (id)valueForUndefinedKey:(NSString *)key
{
    return nil;
}

/* Properties */

- (id<IKDeviceBrowserViewDelegate>)delegate { return _ikDelegate; }
- (void)setDelegate:(id<IKDeviceBrowserViewDelegate>)delegate { _ikDelegate = delegate; }
- (BOOL)isInitialized { return _initialized; }
- (void)setIsInitialized:(BOOL)flag { _initialized = flag; }
- (BOOL)displaysAccessoryView { return _accessoryView; }
- (void)setDisplaysAccessoryView:(BOOL)flag { _accessoryView = flag; }
- (void)setHidesAccessoryView:(BOOL)flag { _accessoryView = !flag; }
- (void)setHidesExtrasContainer:(BOOL)flag { }
- (void)setHidesResizeView:(BOOL)flag { }
- (IKDeviceBrowserViewDisplayMode)mode { return _mode; }
- (void)setMode:(IKDeviceBrowserViewDisplayMode)mode { _mode = mode; }
- (ICDevice *)selectedDevice { return _selected; }
- (ICDeviceBrowser *)deviceBrowser { return _browser; }
- (BOOL)displaysLocalCameras { return _localCameras; }
- (BOOL)displaysNetworkCameras { return _networkCameras; }
- (BOOL)displaysLocalScanners { return _localScanners; }
- (BOOL)displaysNetworkScanners { return _networkScanners; }

- (ICDeviceTypeMask)browsedMask
{
    NSUInteger mask = 0;
    if (_localCameras || _networkCameras)
        mask |= ICDeviceTypeMaskCamera;
    if (_localScanners || _networkScanners)
        mask |= ICDeviceTypeMaskScanner;
    if (_localCameras || _localScanners)
        mask |= ICDeviceLocationTypeMaskLocal;
    if (_networkCameras || _networkScanners)
        mask |= ICDeviceLocationTypeMaskRemote;
    return (ICDeviceTypeMask)mask;
}

- (void)displaysChanged
{
    [_browser setBrowsedDeviceTypeMask:[self browsedMask]];
    [self setNeedsDisplay:YES];
}

- (void)setDisplaysLocalCameras:(BOOL)flag { _localCameras = flag; [self displaysChanged]; }
- (void)setDisplaysNetworkCameras:(BOOL)flag { _networkCameras = flag; [self displaysChanged]; }
- (void)setDisplaysLocalScanners:(BOOL)flag { _localScanners = flag; [self displaysChanged]; }
- (void)setDisplaysNetworkScanners:(BOOL)flag { _networkScanners = flag; [self displaysChanged]; }

- (NSSize)intrinsicContentSize
{
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

/* Browsing, while in a window */

/* The browser starts when the view first goes into a window and, as Apple's, keeps browsing
   when the view leaves it; it stops when the view goes away. */
- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if (![self window])
        return;
    if (!_browser) {
        _browser = [ICDeviceBrowser new];
        [_browser setDelegate:self];
    }
    [_browser setBrowsedDeviceTypeMask:[self browsedMask]];
    [_browser start];
}

- (void)takeoverICDeviceBrowser
{
}

- (BOOL)shows:(ICDevice *)device
{
    ICDeviceType type = [device type];
    BOOL remote = (type & ICDeviceLocationTypeMaskRemote) != 0;
    if (type & ICDeviceTypeMaskCamera)
        return remote ? _networkCameras : _localCameras;
    if (type & ICDeviceTypeMaskScanner)
        return remote ? _networkScanners : _localScanners;
    return NO;
}

- (void)countChanged
{
    id d = _ikDelegate;
    if ([d respondsToSelector:@selector(deviceBrowserView:numberOfDevicesChanged:)])
        [d deviceBrowserView:self numberOfDevicesChanged:@([_shown count])];
    [self setNeedsDisplay:YES];
}

- (void)setSelectedDevice:(ICDevice *)device
{
    if (device == _selected)
        return;
    [_selected release];
    _selected = [device retain];
    [self setNeedsDisplay:YES];
    [_ikDelegate deviceBrowserView:self selectionDidChange:_selected];
}

- (void)deviceBrowser:(ICDeviceBrowser *)browser didAddDevice:(ICDevice *)device moreComing:(BOOL)moreComing
{
    if (![self shows:device] || [_shown containsObject:device])
        return;
    [_shown addObject:device];
    [self countChanged];
    if (!_selected && !moreComing)
        [self setSelectedDevice:[_shown firstObject]];
}

- (void)deviceBrowser:(ICDeviceBrowser *)browser didRemoveDevice:(ICDevice *)device moreGoing:(BOOL)moreGoing
{
    if (![_shown containsObject:device])
        return;
    [[device retain] autorelease];
    [_shown removeObject:device];
    [self countChanged];
    if (device == _selected)
        [self setSelectedDevice:[_shown firstObject]];
}

- (void)deviceBrowser:(ICDeviceBrowser *)browser deviceDidChangeName:(ICDevice *)device
{
    [self setNeedsDisplay:YES];
}

- (void)deviceBrowserDidEnumerateLocalDevices:(ICDeviceBrowser *)browser
{
    id d = _ikDelegate;
    if ([d respondsToSelector:@selector(deviceBrowserView:deviceBrowserDidEnumerateLocalDevices:)])
        [d deviceBrowserView:self deviceBrowserDidEnumerateLocalDevices:browser];
}

/* Drawing: group headings, the devices under them (or "No Devices"). */

- (NSArray *)sections
{
    NSMutableArray *local = [NSMutableArray array], *shared = [NSMutableArray array];
    for (ICDevice *d in _shown)
        [(([d type] & ICDeviceLocationTypeMaskRemote) ? shared : local) addObject:d];
    NSMutableArray *sections = [NSMutableArray array];
    [sections addObject:@[ @"DEVICES", local ]];
    if (_networkCameras || _networkScanners)
        [sections addObject:@[ @"SHARED", shared ]];
    return sections;
}

/* Walk the rows top-down, calling row(y of the row's top, heading or nil, device or nil). */
- (void)eachRow:(void (^)(CGFloat top, NSString *heading, ICDevice *device))row
{
    CGFloat y = 0;
    for (NSArray *section in [self sections]) {
        row(y, section[0], nil);
        y += kHeaderHeight;
        NSArray *devices = section[1];
        if (![devices count]) {
            row(y, nil, nil); /* an empty section keeps one (placeholder) row */
            y += kRowHeight;
        }
        for (ICDevice *d in devices) {
            row(y, nil, d);
            y += kRowHeight;
        }
    }
}

- (void)drawRect:(NSRect)dirty
{
    NSRect b = [self bounds];
    NSDictionary *heading = @{
        NSFontAttributeName : [NSFont boldSystemFontOfSize:11],
        NSForegroundColorAttributeName : [NSColor secondaryLabelColor],
    };
    NSDictionary *placeholder = @{
        NSFontAttributeName : [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName : [NSColor tertiaryLabelColor],
    };
    NSDictionary *name = @{
        NSFontAttributeName : [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName : [NSColor labelColor],
    };
    __block BOOL placed = NO;
    [self eachRow:^(CGFloat top, NSString *title, ICDevice *device) {
        CGFloat height = title ? kHeaderHeight : kRowHeight;
        NSRect r = NSMakeRect(NSMinX(b), NSMaxY(b) - top - height, NSWidth(b), height);
        if (!NSIntersectsRect(r, dirty))
            return;
        if (title) {
            NSSize s = [title sizeWithAttributes:heading];
            [title drawAtPoint:NSMakePoint(kInset, NSMinY(r) + 7 + (14 - s.height) / 2) withAttributes:heading];
        } else if (device) {
            if (device == _selected) {
                [[NSColor unemphasizedSelectedContentBackgroundColor] setFill];
                [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 10, 2) xRadius:5 yRadius:5] fill];
            }
            NSString *n = [device name] ?: @"";
            NSSize s = [n sizeWithAttributes:name];
            [n drawAtPoint:NSMakePoint(kInset + 4, NSMidY(r) - s.height / 2) withAttributes:name];
        } else if (!placed) {
            placed = YES;
            NSString *n = @"No Devices";
            NSSize s = [n sizeWithAttributes:placeholder];
            [n drawAtPoint:NSMakePoint(kInset + 4, NSMidY(r) - s.height / 2) withAttributes:placeholder];
        }
    }];
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint p = [self convertPoint:[event locationInWindow] fromView:nil];
    CGFloat fromTop = NSMaxY([self bounds]) - p.y;
    __block ICDevice *hit = nil;
    [self eachRow:^(CGFloat top, NSString *title, ICDevice *device) {
        if (device && fromTop >= top && fromTop < top + kRowHeight)
            hit = device;
    }];
    if (hit)
        [self setSelectedDevice:hit];
}

- (void)drawRect_ib:(NSRect)rect
{
    [self drawRect:rect];
}

- (void)installView:(id)view
{
}

- (void)resizeView
{
}

@end
