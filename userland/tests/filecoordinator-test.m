/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-filecoordinator-test: NSFileCoordinator and NSFilePresenter within
 * one process: accessors, presenters told to save, relinquish and reacquire,
 * change, move and deletion notices, intents, cancellation. Prints everything;
 * run it against Apple's Foundation and Finch's (DYLD_FRAMEWORK_PATH) and diff
 * all but the first line.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>

@interface Presenter : NSObject <NSFilePresenter>
@property (copy) NSURL *presentedItemURL;
@property (retain) NSOperationQueue *presentedItemOperationQueue;
@property (copy) NSString *name;
@end

@implementation Presenter
- (void)log:(NSString *)what
{
    @synchronized([Presenter class]) {
        printf("  %s: %s\n", self.name.UTF8String, what.UTF8String);
    }
}
- (void)presentedItemDidChange { [self log:@"didChange"]; }
- (void)presentedItemDidMoveToURL:(NSURL *)u { [self log:[@"moved to " stringByAppendingString:u.lastPathComponent]]; }
- (void)relinquishPresentedItemToWriter:(void (^)(void (^)(void)))writer
{
    [self log:@"relinquish to writer"];
    writer(^{
        [self log:@"reacquire after writer"];
    });
}
- (void)relinquishPresentedItemToReader:(void (^)(void (^)(void)))reader
{
    [self log:@"relinquish to reader"];
    reader(^{
        [self log:@"reacquire after reader"];
    });
}
- (void)savePresentedItemChangesWithCompletionHandler:(void (^)(NSError *))done
{
    [self log:@"save changes"];
    done(nil);
}
- (void)accommodatePresentedItemDeletionWithCompletionHandler:(void (^)(NSError *))done
{
    [self log:@"accommodate deletion"];
    done(nil);
}
@end

static void
settle(void)
{
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        Dl_info dl;
        dladdr((__bridge void *)[NSFileCoordinator class], &dl);
        printf("%s\n", dl.dli_fname);
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-filecoordinator-test"];
        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        NSURL *u = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"doc.txt"]];
        [@"x" writeToURL:u atomically:YES encoding:NSUTF8StringEncoding error:NULL];

        NSFileCoordinator *c = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        printf("purpose %s presenters %lu\n", c.purposeIdentifier.length ? "set" : "none",
               (unsigned long)NSFileCoordinator.filePresenters.count);
        NSError *e = nil;
        __block int ran = 0;
        [c coordinateReadingItemAtURL:u options:0 error:&e byAccessor:^(NSURL *n) {
            ran = 1;
            printf("read accessor same %d\n", [n isEqual:u]);
        }];
        printf("ran %d error %d\n", ran, e != nil);
        [c coordinateWritingItemAtURL:u options:NSFileCoordinatorWritingForReplacing error:&e byAccessor:^(NSURL *n) {
            printf("write accessor same %d\n", [n isEqual:u]);
        }];
        [c coordinateReadingItemAtURL:u options:0 writingItemAtURL:u options:0 error:&e
                           byAccessor:^(NSURL *a, NSURL *b) {
                               printf("read and write accessor\n");
                           }];

        Presenter *p = [Presenter new];
        p.name = @"presenter";
        p.presentedItemURL = u;
        NSOperationQueue *q = [NSOperationQueue new];
        q.maxConcurrentOperationCount = 1;
        p.presentedItemOperationQueue = q;
        [NSFileCoordinator addFilePresenter:p];
        printf("presenters %lu\n", (unsigned long)NSFileCoordinator.filePresenters.count);

        printf("-- another coordinator writes\n");
        NSFileCoordinator *c2 = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [c2 coordinateWritingItemAtURL:u options:0 error:&e byAccessor:^(NSURL *n) {
            printf("  write accessor\n");
        }];
        [q waitUntilAllOperationsAreFinished];
        settle();
        printf("-- another coordinator reads\n");
        [c2 coordinateReadingItemAtURL:u options:0 error:&e byAccessor:^(NSURL *n) {
            printf("  read accessor\n");
        }];
        [q waitUntilAllOperationsAreFinished];
        settle();
        printf("-- reads without changes\n");
        [c2 coordinateReadingItemAtURL:u options:NSFileCoordinatorReadingWithoutChanges error:&e
                            byAccessor:^(NSURL *n) {
                                printf("  read accessor\n");
                            }];
        [q waitUntilAllOperationsAreFinished];
        settle();
        printf("-- the presenter's own coordinator writes\n");
        NSFileCoordinator *own = [[NSFileCoordinator alloc] initWithFilePresenter:p];
        [own coordinateWritingItemAtURL:u options:0 error:&e byAccessor:^(NSURL *n) {
            printf("  write accessor\n");
        }];
        [q waitUntilAllOperationsAreFinished];
        settle();
        printf("-- a move\n");
        NSURL *moved = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"moved.txt"]];
        [c2 coordinateWritingItemAtURL:u options:NSFileCoordinatorWritingForMoving error:&e byAccessor:^(NSURL *n) {
            [[NSFileManager defaultManager] moveItemAtURL:n toURL:moved error:NULL];
            [c2 itemAtURL:n didMoveToURL:moved];
        }];
        [q waitUntilAllOperationsAreFinished];
        settle();
        [q waitUntilAllOperationsAreFinished];
        printf("-- a deletion\n");
        p.presentedItemURL = moved;
        [c2 coordinateWritingItemAtURL:moved options:NSFileCoordinatorWritingForDeleting error:&e
                            byAccessor:^(NSURL *n) {
                                [[NSFileManager defaultManager] removeItemAtURL:n error:NULL];
                            }];
        [q waitUntilAllOperationsAreFinished];
        settle();
        [NSFileCoordinator removeFilePresenter:p];
        printf("presenters %lu\n", (unsigned long)NSFileCoordinator.filePresenters.count);

        NSFileAccessIntent *intent = [NSFileAccessIntent readingIntentWithURL:u options:0];
        __block int done = 0;
        [c coordinateAccessWithIntents:@[ intent ] queue:[NSOperationQueue mainQueue] byAccessor:^(NSError *err) {
            done = 1;
            printf("intent accessor url same %d error %d main %d\n", [intent.URL isEqual:u], err != nil,
                   [NSThread isMainThread]);
        }];
        printf("intent ran at once %d\n", done);
        settle();
        printf("intent ran %d\n", done);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
    }
    return 0;
}
