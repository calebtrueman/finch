/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * ICDevice and its two kinds, ICCameraDevice and ICScannerDevice.
 *
 * The properties are the headers' own (synthesized). Without device modules
 * nothing creates these yet; if something does, a request fails the way
 * Apple's does when the device has gone: the delegate (or completion) gets an
 * ICErrorDomain error, on the main thread for delegates.
 */
#import <ImageCaptureCore/ImageCaptureCore.h>
#import <objc/message.h>

#pragma clang diagnostic ignored "-Wavailability"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

static NSError *
ic_error(NSInteger code)
{
    return [NSError errorWithDomain:ICErrorDomain code:code userInfo:nil];
}

/* Send sel (device, error) to the delegate on the main thread, if it implements it. */
static void
tell(id delegate, SEL sel, ICDevice *device, NSInteger code)
{
    if (![delegate respondsToSelector:sel])
        return;
    NSError *error = code ? ic_error(code) : nil;
    [device retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, device, error);
        [device release];
    });
}

static void
complete(void (^completion)(NSError *), NSInteger code)
{
    if (!completion)
        return;
    NSError *error = ic_error(code);
    completion = [completion copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(error);
        [completion release];
    });
}

@implementation ICDevice {
    NSArray *_capabilities;
    NSMutableDictionary *_userData;
}

- (void)dealloc
{
    [_name release];
    [_productKind release];
    CGImageRelease(_icon);
    [_systemSymbolName release];
    [_transportType release];
    [_UUIDString release];
    [_locationDescription release];
    [_userData release];
    [_modulePath release];
    [_moduleVersion release];
    [_serialNumberString release];
    [_capabilities release];
    [_autolaunchApplicationPath release];
    [_persistentIDString release];
    [super dealloc];
}

- (NSArray *)capabilities
{
    return _capabilities ?: @[];
}

- (NSMutableDictionary *)userData
{
    if (!_userData)
        _userData = [NSMutableDictionary new];
    return _userData;
}

- (BOOL)isRemote
{
    return (_type & ICDeviceLocationTypeMaskRemote) != 0;
}

- (int)moduleExecutableArchitecture
{
    return 0;
}

- (void)requestOpenSession
{
    tell(_delegate, @selector(device:didOpenSessionWithError:), self, ICReturnDeviceFailedToOpenSession);
}

- (void)requestCloseSession
{
    tell(_delegate, @selector(device:didCloseSessionWithError:), self, ICReturnSessionNotOpened);
}

- (void)requestEject
{
    tell(_delegate, @selector(device:didEjectWithError:), self, ICReturnConnectionEjectFailed);
}

- (void)requestEjectOrDisconnect
{
    [self requestEject];
}

- (void)requestYield
{
}

- (void)requestOpenSessionWithOptions:(NSDictionary *)options completion:(void (^)(NSError *))completion
{
    complete(completion, ICReturnDeviceFailedToOpenSession);
}

- (void)requestCloseSessionWithOptions:(NSDictionary *)options completion:(void (^)(NSError *))completion
{
    complete(completion, ICReturnSessionNotOpened);
}

- (void)requestEjectWithCompletion:(void (^)(NSError *))completion
{
    complete(completion, ICReturnConnectionEjectFailed);
}

- (void)requestSendMessage:(unsigned int)messageCode outData:(NSData *)data
       maxReturnedDataSize:(unsigned int)maxReturnedDataSize sendMessageDelegate:(id)sendMessageDelegate
    didSendMessageSelector:(SEL)selector contextInfo:(void *)contextInfo
{
    if (!sendMessageDelegate || !selector || ![sendMessageDelegate respondsToSelector:selector])
        return;
    NSError *error = ic_error(ICReturnFailedToCompleteSendMessageRequest);
    [sendMessageDelegate retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, UInt32, id, id, void *))objc_msgSend)(sendMessageDelegate, selector, messageCode, nil,
                                                                  error, contextInfo);
        [sendMessageDelegate release];
    });
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> name: %@ type: 0x%lx", [self class], self, _name,
                                      (unsigned long)_type];
}

@end

@implementation ICCameraDevice

- (void)dealloc
{
    [_contents release];
    [_mediaFiles release];
    [_mountPoint release];
    [_ptpEventHandler release];
    [super dealloc];
}

- (NSArray *)filesOfType:(NSString *)fileUTType
{
    return @[];
}

- (void)requestReadDataFromFile:(ICCameraFile *)file atOffset:(off_t)offset length:(off_t)length
             readDelegate:(id)readDelegate didReadDataSelector:(SEL)selector contextInfo:(void *)contextInfo
{
    if (!readDelegate || !selector || ![readDelegate respondsToSelector:selector])
        return;
    NSError *error = ic_error(ICReturnCodeObjectCouldNotBeRead);
    [readDelegate retain];
    [file retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, id, id, void *))objc_msgSend)(readDelegate, selector, nil, file, error, contextInfo);
        [file release];
        [readDelegate release];
    });
}

- (void)requestDownloadFile:(ICCameraFile *)file options:(NSDictionary *)options
           downloadDelegate:(id<ICCameraDeviceDownloadDelegate>)downloadDelegate
        didDownloadSelector:(SEL)selector contextInfo:(void *)contextInfo
{
    if (!downloadDelegate || !selector || ![(id)downloadDelegate respondsToSelector:selector])
        return;
    NSError *error = ic_error(ICReturnDownloadFailed);
    [(id)downloadDelegate retain];
    [file retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, id, id, void *))objc_msgSend)(downloadDelegate, selector, file, error, options,
                                                              contextInfo);
        [file release];
        [(id)downloadDelegate release];
    });
}

- (void)cancelDownload
{
}

- (void)requestDeleteFiles:(NSArray *)files
{
    id d = self.delegate;
    if ([d respondsToSelector:@selector(cameraDevice:didCompleteDeleteFilesWithError:)]) {
        NSError *error = ic_error(ICReturnDeleteFilesFailed);
        [self retain];
        dispatch_async(dispatch_get_main_queue(), ^{
            [d cameraDevice:self didCompleteDeleteFilesWithError:error];
            [self release];
        });
    }
}

- (NSProgress *)requestDeleteFiles:(NSArray *)files
                      deleteFailed:(void (^)(NSDictionary<ICDeleteError, ICCameraItem *> *))deleteFailed
                        completion:(void (^)(NSDictionary<ICDeleteResult, NSArray<ICCameraItem *> *> *,
                                             NSError *))completion
{
    NSProgress *progress = [NSProgress progressWithTotalUnitCount:(int64_t)[files count]];
    if (completion) {
        NSDictionary *result = @{ ICDeleteSuccessful : @[], ICDeleteCanceled : @[], ICDeleteFailed : files ?: @[] };
        NSError *error = ic_error(ICReturnDeleteFilesFailed);
        completion = [completion copy];
        [result retain];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            completion(result, error);
            [result release];
            [completion release];
        });
    }
    return progress;
}

- (void)cancelDelete
{
}

- (void)requestSyncClock
{
}

- (void)requestUploadFile:(NSURL *)fileURL options:(NSDictionary *)options uploadDelegate:(id)uploadDelegate
        didUploadSelector:(SEL)selector contextInfo:(void *)contextInfo
{
}

- (void)requestTakePicture
{
}

- (void)requestEnableTethering
{
}

- (void)requestDisableTethering
{
}

- (void)requestSendPTPCommand:(NSData *)command outData:(NSData *)data sendCommandDelegate:(id)sendCommandDelegate
       didSendCommandSelector:(SEL)selector contextInfo:(void *)contextInfo
{
    if (!sendCommandDelegate || !selector || ![sendCommandDelegate respondsToSelector:selector])
        return;
    NSError *error = ic_error(ICReturnPTPFailedToSendCommand);
    [sendCommandDelegate retain];
    [command retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, id, id, id, void *))objc_msgSend)(sendCommandDelegate, selector, command, nil, nil,
                                                                  error, contextInfo);
        [command release];
        [sendCommandDelegate release];
    });
}

- (void)requestSendPTPCommand:(NSData *)ptpCommand
                      outData:(NSData *)ptpData
                   completion:(void (^)(NSData *, NSData *, NSError *))completion
{
    if (!completion)
        return;
    NSError *error = ic_error(ICReturnPTPFailedToSendCommand);
    completion = [completion copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(nil, nil, error);
        [completion release];
    });
}

@end

@implementation ICScannerDevice {
    NSArray *_availableFunctionalUnitTypes;
}

- (void)dealloc
{
    [_availableFunctionalUnitTypes release];
    [_selectedFunctionalUnit release];
    [_downloadsDirectory release];
    [_documentName release];
    [_documentUTI release];
    [_defaultUsername release];
    [super dealloc];
}

- (NSArray *)availableFunctionalUnitTypes
{
    return _availableFunctionalUnitTypes ?: @[];
}

- (void)requestOpenSessionWithCredentials:(NSString *)username password:(NSString *)password
{
    [self requestOpenSession];
}

static void
scanner_tell(ICScannerDevice *scanner, SEL sel, NSInteger code)
{
    tell(scanner.delegate, sel, scanner, code);
}

- (void)requestSelectFunctionalUnit:(ICScannerFunctionalUnitType)type
{
    id d = self.delegate;
    if (![d respondsToSelector:@selector(scannerDevice:didSelectFunctionalUnit:error:)])
        return;
    NSError *error = ic_error(ICReturnScannerFailedToSelectFunctionalUnit);
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [d scannerDevice:self didSelectFunctionalUnit:self.selectedFunctionalUnit error:error];
        [self release];
    });
}

- (void)requestOverviewScan
{
    scanner_tell(self, @selector(scannerDevice:didCompleteOverviewScanWithError:),
                 ICReturnScannerFailedToCompleteOverviewScan);
}

- (void)requestScan
{
    scanner_tell(self, @selector(scannerDevice:didCompleteScanWithError:), ICReturnScannerFailedToCompleteScan);
}

- (void)cancelScan
{
}

@end
