/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The items on a camera: ICCameraItem, ICCameraFolder and ICCameraFile.
 * Properties are the headers' own (synthesized); the requests answer with an
 * ICErrorDomain error, as no device module serves them yet.
 */
#import <ImageCaptureCore/ImageCaptureCore.h>

#pragma clang diagnostic ignored "-Wavailability"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"

static void
fail(void (^completion)(id, NSError *), NSInteger code)
{
    if (!completion)
        return;
    NSError *error = [NSError errorWithDomain:ICErrorDomain code:code userInfo:nil];
    completion = [completion copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(nil, error);
        [completion release];
    });
}

@implementation ICCameraItem {
    NSMutableDictionary *_userData;
}

- (void)dealloc
{
    [_name release];
    [_UTI release];
    [_fileSystemPath release];
    [_creationDate release];
    [_modificationDate release];
    CGImageRelease(_thumbnail);
    [_metadata release];
    [_userData release];
    [super dealloc];
}

- (NSMutableDictionary *)userData
{
    if (!_userData)
        _userData = [NSMutableDictionary new];
    return _userData;
}

- (void)requestThumbnail
{
}

- (void)requestMetadata
{
}

- (void)flushThumbnailCache
{
}

- (void)flushMetadataCache
{
}

- (CGImageRef)thumbnailIfAvailable { return _thumbnail; }
- (CGImageRef)largeThumbnailIfAvailable { return _thumbnail; }
- (NSDictionary *)metadataIfAvailable { return _metadata; }

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p> name: %@", [self class], self, _name];
}

@end

@implementation ICCameraFolder

- (void)dealloc
{
    [_contents release];
    [super dealloc];
}

@end

@implementation ICCameraFile

- (void)dealloc
{
    [_originalFilename release];
    [_createdFilename release];
    [_originatingAssetID release];
    [_groupUUID release];
    [_gpsString release];
    [_relatedUUID release];
    [_burstUUID release];
    [_sidecarFiles release];
    [_pairedRawImage release];
    [_fileCreationDate release];
    [_fileModificationDate release];
    [_exifCreationDate release];
    [_exifModificationDate release];
    [_fingerprint release];
    [super dealloc];
}

+ (NSString *)fingerprintForFileAtURL:(NSURL *)url
{
    return nil;
}

- (void)requestThumbnailDataWithOptions:(NSDictionary *)options completion:(void (^)(NSData *, NSError *))completion
{
    fail((void (^)(id, NSError *))completion, ICReturnThumbnailNotAvailable);
}

- (void)requestMetadataDictionaryWithOptions:(NSDictionary *)options
                                  completion:(void (^)(NSDictionary *, NSError *))completion
{
    fail((void (^)(id, NSError *))completion, ICReturnMetadataNotAvailable);
}

- (NSProgress *)requestDownloadWithOptions:(NSDictionary *)options completion:(void (^)(NSString *, NSError *))completion
{
    fail((void (^)(id, NSError *))completion, ICReturnDownloadFailed);
    return [NSProgress progressWithTotalUnitCount:0];
}

- (void)requestReadDataAtOffset:(off_t)offset length:(off_t)length completion:(void (^)(NSData *, NSError *))completion
{
    fail((void (^)(id, NSError *))completion, ICReturnCodeObjectCouldNotBeRead);
}

- (void)requestSecurityScopedURLWithCompletion:(void (^)(NSURL *, NSError *))completion
{
    fail((void (^)(id, NSError *))completion, ICReturnCodeObjectDoesNotExist);
}

- (void)requestFingerprintWithCompletion:(void (^)(NSString *, NSError *))completion
{
    fail((void (^)(id, NSError *))completion, ICReturnCodeObjectDoesNotExist);
}

@end
