/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSFileCoordinator and NSFileAccessIntent, within the process: the file
 * presenters registered here are told about reads, writes, moves and
 * deletions of their items, on their own operation queues, as Apple's are
 * (save before others read, relinquish around access, didChange after a
 * write, move and deletion notices). Finch has no file-coordination daemon
 * yet, so presenters in other processes aren't told.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>

#include "Foundation_Finch.h"

@implementation NSFileAccessIntent {
    NSURL *_url;
    BOOL _writing;
    NSUInteger _options;
}

+ (instancetype)readingIntentWithURL:(NSURL *)url options:(NSFileCoordinatorReadingOptions)options
{
    NSFileAccessIntent *i = [[[self alloc] init] autorelease];
    i->_url = [url copy];
    i->_options = options;
    return i;
}

+ (instancetype)writingIntentWithURL:(NSURL *)url options:(NSFileCoordinatorWritingOptions)options
{
    NSFileAccessIntent *i = [[[self alloc] init] autorelease];
    i->_url = [url copy];
    i->_options = options;
    i->_writing = YES;
    return i;
}

- (void)dealloc
{
    [_url release];
    [super dealloc];
}

- (NSURL *)URL { return _url; }
- (BOOL)_finchWriting { return _writing; }
- (NSUInteger)_finchOptions { return _options; }

@end

static NSMutableArray *presenters; /* the registered NSFilePresenters, not retained */
static NSString *const kLock = @"NSFileCoordinatorPresenters";

@implementation NSFileCoordinator {
    id<NSFilePresenter> _presenter; /* not retained */
    NSString *_purpose;
    BOOL _cancelled;
}

+ (void)addFilePresenter:(id<NSFilePresenter>)presenter
{
    @synchronized(kLock) {
        if (!presenters)
            presenters = (NSMutableArray *)CFArrayCreateMutable(NULL, 0, NULL);
        if (![presenters containsObject:presenter])
            [presenters addObject:presenter];
    }
}

+ (void)removeFilePresenter:(id<NSFilePresenter>)presenter
{
    @synchronized(kLock) {
        [presenters removeObjectIdenticalTo:presenter];
    }
}

+ (NSArray<id<NSFilePresenter>> *)filePresenters
{
    @synchronized(kLock) {
        NSMutableArray *a = [NSMutableArray array];
        for (id p in presenters)
            [a addObject:p];
        return a;
    }
}

- (instancetype)initWithFilePresenter:(id<NSFilePresenter>)presenter
{
    self = [super init];
    if (self) {
        _presenter = presenter;
        _purpose = [[[NSUUID UUID] UUIDString] copy];
    }
    return self;
}

- (instancetype)init { return [self initWithFilePresenter:nil]; }

- (void)dealloc
{
    [_purpose release];
    [super dealloc];
}

- (NSString *)purposeIdentifier { return _purpose; }
- (void)setPurposeIdentifier:(NSString *)p
{
    [_purpose autorelease];
    _purpose = [p copy];
}

- (void)cancel { _cancelled = YES; }

#pragma mark Presenters

/* The other presenters of the item, of an item inside it, or of a folder around it. */
- (NSArray *)_presentersFor:(NSURL *)url
{
    NSString *path = [[url URLByStandardizingPath] path];
    NSMutableArray *found = [NSMutableArray array];
    for (id<NSFilePresenter> p in [NSFileCoordinator filePresenters]) {
        if (p == _presenter)
            continue;
        if (_purpose && [p respondsToSelector:@selector(presentedItemOperationQueue)] &&
            [p respondsToSelector:@selector(filePresenterPurposeIdentifier)] && [_purpose isEqual:[(id)p filePresenterPurposeIdentifier]])
            continue;
        NSString *mine = [[[p presentedItemURL] URLByStandardizingPath] path];
        if (!mine)
            continue;
        if ([mine isEqualToString:path] || [path hasPrefix:[mine stringByAppendingString:@"/"]] ||
            [mine hasPrefix:[path stringByAppendingString:@"/"]])
            [found addObject:p];
    }
    return found;
}

/* Runs a block on the presenter's queue and waits (inline when that queue is the current one). */
static void
on_queue(id<NSFilePresenter> p, void (^block)(void))
{
    NSOperationQueue *q = [p presentedItemOperationQueue];
    if (!q || q == [NSOperationQueue currentQueue]) {
        block();
        return;
    }
    NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:block];
    [q addOperations:@[ op ] waitUntilFinished:YES];
}

/*
 * Reacquirers after writes wait for the next coordination that involves
 * their presenter, as Apple's do (a deletion's run at once).
 */
static NSMutableArray *deferred; /* of @[presenter, reacquirer] */

static void
flush_deferred(NSArray *ps)
{
    NSMutableArray *run = [NSMutableArray array];
    @synchronized(kLock) {
        for (NSArray *pair in [[deferred copy] autorelease])
            if ([ps indexOfObjectIdenticalTo:pair[0]] != NSNotFound) {
                [run addObject:pair];
                [deferred removeObjectIdenticalTo:pair];
            }
    }
    for (NSArray *pair in run)
        on_queue(pair[0], pair[1]);
}

/* Asks the presenters to step aside (and, before others read, to save); returns their reacquirers. */
- (NSArray *)_relinquish:(NSArray *)ps forWriting:(BOOL)writing save:(BOOL)save
{
    flush_deferred(ps);
    NSMutableArray *reacquirers = [NSMutableArray array];
    for (id<NSFilePresenter> p in ps) {
        SEL sel = writing ? @selector(relinquishPresentedItemToWriter:) : @selector(relinquishPresentedItemToReader:);
        if ([p respondsToSelector:sel])
            on_queue(p, ^{
                ((void (*)(id, SEL, id))objc_msgSend)(p, sel, ^(void (^reacquirer)(void)) {
                    if (reacquirer)
                        [reacquirers addObject:@[ p, [[reacquirer copy] autorelease] ]];
                });
            });
        if (save && [p respondsToSelector:@selector(savePresentedItemChangesWithCompletionHandler:)])
            on_queue(p, ^{
                dispatch_semaphore_t done = dispatch_semaphore_create(0);
                [p savePresentedItemChangesWithCompletionHandler:^(NSError *e) {
                    dispatch_semaphore_signal(done);
                }];
                dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
                dispatch_release(done);
            });
    }
    return reacquirers;
}

static void
reacquire(NSArray *reacquirers)
{
    for (NSArray *pair in reacquirers)
        on_queue(pair[0], pair[1]);
}

static void
reacquire_later(NSArray *reacquirers)
{
    @synchronized(kLock) {
        if (!deferred)
            deferred = [[NSMutableArray alloc] init];
        [deferred addObjectsFromArray:reacquirers];
    }
}

/* What a write is judged by: the item's modification date and size. */
static NSArray *
stamp(NSURL *url)
{
    NSDictionary *a = [[NSFileManager defaultManager] attributesOfItemAtPath:[url path] error:NULL];
    return a ? @[ a[NSFileModificationDate] ?: [NSNull null], a[NSFileSize] ?: [NSNull null] ] : @[];
}

- (BOOL)_cancelledError:(NSError **)outError
{
    if (!_cancelled)
        return NO;
    if (outError)
        *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
    return YES;
}

#pragma mark Coordinating

- (void)coordinateReadingItemAtURL:(NSURL *)url options:(NSFileCoordinatorReadingOptions)options
                             error:(NSError **)outError
                        byAccessor:(void (NS_NOESCAPE ^)(NSURL *newURL))reader
{
    if ([self _cancelledError:outError])
        return;
    NSArray *ps = [self _presentersFor:url];
    NSArray *re = [self _relinquish:ps forWriting:NO save:!(options & NSFileCoordinatorReadingWithoutChanges)];
    reader(url);
    reacquire(re);
}

- (void)coordinateWritingItemAtURL:(NSURL *)url options:(NSFileCoordinatorWritingOptions)options
                             error:(NSError **)outError
                        byAccessor:(void (NS_NOESCAPE ^)(NSURL *newURL))writer
{
    if ([self _cancelledError:outError])
        return;
    NSArray *ps = [self _presentersFor:url];
    NSArray *re = [self _relinquish:ps forWriting:YES save:NO];
    if (options & NSFileCoordinatorWritingForDeleting) {
        for (id<NSFilePresenter> p in ps)
            if ([p respondsToSelector:@selector(accommodatePresentedItemDeletionWithCompletionHandler:)])
                on_queue(p, ^{
                    dispatch_semaphore_t done = dispatch_semaphore_create(0);
                    [p accommodatePresentedItemDeletionWithCompletionHandler:^(NSError *e) {
                        dispatch_semaphore_signal(done);
                    }];
                    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
                    dispatch_release(done);
                });
    }
    NSArray *before = stamp(url);
    writer(url);
    if (options & NSFileCoordinatorWritingForDeleting)
        reacquire(re);
    else
        reacquire_later(re);
    if (!(options & (NSFileCoordinatorWritingForDeleting | NSFileCoordinatorWritingForMoving)) &&
        ![stamp(url) isEqualToArray:before])
        for (id<NSFilePresenter> p in ps)
            if ([p respondsToSelector:@selector(presentedItemDidChange)])
                [[p presentedItemOperationQueue] addOperationWithBlock:^{
                    [p presentedItemDidChange];
                }];
}

- (void)coordinateReadingItemAtURL:(NSURL *)readingURL options:(NSFileCoordinatorReadingOptions)readingOptions
                  writingItemAtURL:(NSURL *)writingURL options:(NSFileCoordinatorWritingOptions)writingOptions
                             error:(NSError **)outError
                        byAccessor:(void (NS_NOESCAPE ^)(NSURL *newReadingURL, NSURL *newWritingURL))readerWriter
{
    if ([self _cancelledError:outError])
        return;
    [self coordinateWritingItemAtURL:writingURL options:writingOptions error:outError
                          byAccessor:^(NSURL *w) {
                              readerWriter(readingURL, w);
                          }];
}

- (void)coordinateWritingItemAtURL:(NSURL *)url1 options:(NSFileCoordinatorWritingOptions)options1
                  writingItemAtURL:(NSURL *)url2 options:(NSFileCoordinatorWritingOptions)options2
                             error:(NSError **)outError
                        byAccessor:(void (NS_NOESCAPE ^)(NSURL *newURL1, NSURL *newURL2))writer
{
    if ([self _cancelledError:outError])
        return;
    [self coordinateWritingItemAtURL:url1 options:options1 error:outError
                          byAccessor:^(NSURL *a) {
                              [self coordinateWritingItemAtURL:url2 options:options2 error:outError
                                                    byAccessor:^(NSURL *b) {
                                                        writer(a, b);
                                                    }];
                          }];
}

- (void)prepareForReadingItemsAtURLs:(NSArray<NSURL *> *)readingURLs options:(NSFileCoordinatorReadingOptions)readingOptions
                  writingItemsAtURLs:(NSArray<NSURL *> *)writingURLs options:(NSFileCoordinatorWritingOptions)writingOptions
                               error:(NSError **)outError
                          byAccessor:(void (NS_NOESCAPE ^)(void (^completionHandler)(void)))batchAccessor
{
    if ([self _cancelledError:outError])
        return;
    batchAccessor(^{
    });
}

- (void)coordinateAccessWithIntents:(NSArray<NSFileAccessIntent *> *)intents queue:(NSOperationQueue *)queue
                         byAccessor:(void (^)(NSError *error))accessor
{
    NSOperationQueue *q = queue ?: [NSOperationQueue mainQueue];
    void (^run)(void) = [[^{
        if (_cancelled) {
            accessor([NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]);
            return;
        }
        accessor(nil);
    } copy] autorelease];
    [q addOperationWithBlock:run];
}

#pragma mark Moves and changes

- (void)itemAtURL:(NSURL *)oldURL willMoveToURL:(NSURL *)newURL {}

- (void)itemAtURL:(NSURL *)oldURL didMoveToURL:(NSURL *)newURL
{
    for (id<NSFilePresenter> p in [self _presentersFor:oldURL])
        if ([p respondsToSelector:@selector(presentedItemDidMoveToURL:)])
            [[p presentedItemOperationQueue] addOperationWithBlock:^{
                [p presentedItemDidMoveToURL:newURL];
            }];
}

- (void)itemAtURL:(NSURL *)url didChangeUbiquityAttributes:(NSSet<NSURLResourceKey> *)attributes {}

@end
