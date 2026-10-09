/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ICDeviceBrowser: finds the cameras and scanners Image Capture can talk to.
 *
 * Finch has no camera or scanner support yet (no PTP, mass-storage or eSCL
 * device modules, no imagecaptureagent), so the browser finds no devices.
 * Otherwise it behaves as Apple's does on a Mac with nothing attached:
 *
 *   - browsedDeviceTypeMask starts as camera | local (0x101) and takes any value;
 *   - devices is an empty array, never nil;
 *   - -start without a delegate is ignored (isBrowsing stays NO);
 *   - with a delegate, -start sets isBrowsing and, from the run loop on the
 *     main thread, sends deviceBrowserDidEnumerateLocalDevices: if the delegate
 *     implements it (no deviceBrowser:didAddDevice:moreComing: as there is nothing to add);
 *   - -stop clears isBrowsing.
 *
 * The add and remove paths (-addDevice:moreComing:, -removeDevice:moreGoing:,
 * the names Apple's uses) are here for the device modules to come.
 */
#import <ImageCaptureCore/ImageCaptureCore.h>

#pragma clang diagnostic ignored "-Wavailability"

@interface ICDeviceBrowser (Finch)
- (void)addDevice:(ICDevice *)device moreComing:(BOOL)moreComing;
- (void)removeDevice:(ICDevice *)device moreGoing:(BOOL)moreGoing;
- (BOOL)containsDevice:(ICDevice *)device;
@end

@implementation ICDeviceBrowser {
    id<ICDeviceBrowserDelegate> _delegate;
    BOOL _browsing;
    ICDeviceTypeMask _mask;
    NSMutableArray *_devices;
    NSUInteger _generation; /* bumped by -stop, so a pending enumeration from an earlier -start is dropped */
}

- (instancetype)init
{
    if ((self = [super init])) {
        _mask = ICDeviceTypeMaskCamera | ICDeviceLocationTypeMaskLocal;
        _devices = [NSMutableArray new];
    }
    return self;
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [_devices release];
    [super dealloc];
}

- (id<ICDeviceBrowserDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<ICDeviceBrowserDelegate>)delegate { _delegate = delegate; }
- (BOOL)isBrowsing { return _browsing; }
- (BOOL)isSuspended { return NO; }
- (ICDeviceTypeMask)browsedDeviceTypeMask { return _mask; }
- (void)setBrowsedDeviceTypeMask:(ICDeviceTypeMask)mask { _mask = mask; }

- (NSArray *)devices
{
    @synchronized(self) {
        return [[_devices copy] autorelease];
    }
}

- (ICDevice *)preferredDevice
{
    return nil;
}

- (void)start
{
    if (!_delegate || _browsing)
        return;
    _browsing = YES;
    /* Local devices are enumerated by now (there are none): say so from the run loop, as Apple's
       does once its agent has answered. */
    [self performSelector:@selector(_finchDidEnumerateLocalDevices:) withObject:@(_generation)
               afterDelay:0 inModes:@[ NSRunLoopCommonModes ]];
}

- (void)_finchDidEnumerateLocalDevices:(NSNumber *)generation
{
    if (!_browsing || [generation unsignedIntegerValue] != _generation)
        return;
    id d = _delegate;
    if ([d respondsToSelector:@selector(deviceBrowserDidEnumerateLocalDevices:)])
        [d deviceBrowserDidEnumerateLocalDevices:self];
}

- (void)stop
{
    _browsing = NO;
    _generation++;
}

- (BOOL)containsDevice:(ICDevice *)device
{
    @synchronized(self) {
        return [_devices containsObject:device];
    }
}

- (void)addDevice:(ICDevice *)device moreComing:(BOOL)moreComing
{
    @synchronized(self) {
        if ([_devices containsObject:device])
            return;
        [_devices addObject:device];
    }
    if (_browsing)
        [_delegate deviceBrowser:self didAddDevice:device moreComing:moreComing];
}

- (void)removeDevice:(ICDevice *)device moreGoing:(BOOL)moreGoing
{
    [[device retain] autorelease];
    @synchronized(self) {
        if (![_devices containsObject:device])
            return;
        [_devices removeObject:device];
    }
    if (_browsing)
        [_delegate deviceBrowser:self didRemoveDevice:device moreGoing:moreGoing];
}

/* iOS-only in the headers, but present on macOS (ICAuthorizationStatusAuthorized's value: the constant is unavailable here). */
#define AUTHORIZED @"ICAuthorizationStatusAuthorized"
- (ICAuthorizationStatus)contentsAuthorizationStatus { return AUTHORIZED; }
- (ICAuthorizationStatus)controlAuthorizationStatus { return AUTHORIZED; }

static void
answer(void (^completion)(ICAuthorizationStatus))
{
    if (completion)
        completion(AUTHORIZED);
}

- (void)requestContentsAuthorizationWithCompletion:(void (^)(ICAuthorizationStatus))completion { answer(completion); }
- (void)requestControlAuthorizationWithCompletion:(void (^)(ICAuthorizationStatus))completion { answer(completion); }
- (void)resetContentsAuthorizationWithCompletion:(void (^)(ICAuthorizationStatus))completion { answer(completion); }
- (void)resetControlAuthorizationWithCompletion:(void (^)(ICAuthorizationStatus))completion { answer(completion); }

@end
