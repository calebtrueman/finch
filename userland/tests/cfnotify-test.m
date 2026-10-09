/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-cfnotify-test: CFNotificationCenter's local, Darwin and distributed
 * centers, and the local center's sharing of observers with Foundation's
 * default NSNotificationCenter. Prints everything; run it against Apple's
 * CoreFoundation and Finch's (DYLD_FRAMEWORK_PATH) and diff.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>

static void
callback(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object,
         CFDictionaryRef info)
{
    (void)center;
    NSString *ui = [[(__bridge id)info description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    printf("callback %s: %s object %s info %s main %d\n", (char *)observer, [(__bridge NSString *)name UTF8String],
           object ? [[(__bridge id)object description] UTF8String] : "nil", info ? ui.UTF8String : "nil",
           [NSThread isMainThread]);
}

static void
section(const char *s)
{
    printf("-- %s\n", s);
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        Dl_info dl;
        dladdr((void *)CFNotificationCenterGetLocalCenter, &dl);
        printf("%s\n", dl.dli_fname);

        CFNotificationCenterRef local = CFNotificationCenterGetLocalCenter();
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterRef dist = CFNotificationCenterGetDistributedCenter();
        printf("same %d distinct %d %d type %d class %s\n", local == CFNotificationCenterGetLocalCenter(),
               local != darwin, darwin != dist, CFGetTypeID(local) == CFNotificationCenterGetTypeID(),
               object_getClassName((__bridge id)local));
        printf("is NSNotificationCenter %d\n", (__bridge void *)[NSNotificationCenter defaultCenter] == local);

        CFNotificationCenterAddObserver(local, "A", callback, CFSTR("n1"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(local, "B", callback, NULL, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(local, "C", callback, CFSTR("n1"), (__bridge void *)@"obj",
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        [[NSNotificationCenter defaultCenter] addObserverForName:@"n1"
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *n) {
                                                          printf("NSNotificationCenter block: %s object %s\n",
                                                                 n.name.UTF8String, [[n.object description] UTF8String]);
                                                      }];
        section("post n1");
        CFNotificationCenterPostNotification(local, CFSTR("n1"), NULL, NULL, true);
        section("post n1 with object and info");
        CFNotificationCenterPostNotification(local, CFSTR("n1"), (__bridge void *)@"obj",
                                             (__bridge CFDictionaryRef) @{@"k" : @1}, false);
        section("NSNotificationCenter post n1");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"n1" object:nil];
        section("remove A for n1");
        CFNotificationCenterRemoveObserver(local, "A", CFSTR("n1"), NULL);
        CFNotificationCenterPostNotification(local, CFSTR("n1"), NULL, NULL, true);
        section("remove every B");
        CFNotificationCenterRemoveEveryObserver(local, "B");
        CFNotificationCenterPostNotification(local, CFSTR("n1"), NULL, NULL, true);
        section("any name");
        CFNotificationCenterAddObserver(local, "E", callback, NULL, NULL, 0);
        CFNotificationCenterPostNotificationWithOptions(local, CFSTR("x"), NULL, NULL, 0);
        CFNotificationCenterRemoveEveryObserver(local, "E");

        section("darwin");
        CFNotificationCenterAddObserver(darwin, "D", callback, CFSTR("org.finch.test.cfnotify"), NULL, 0);
        CFNotificationCenterPostNotification(darwin, CFSTR("org.finch.test.cfnotify"), (__bridge void *)@"ignored",
                                             (__bridge CFDictionaryRef) @{@"k" : @1}, true);
        printf("posted\n");
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);

        section("distributed");
        CFNotificationCenterAddObserver(dist, "R", callback, CFSTR("org.finch.test.cfnotify.dist"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterPostNotification(dist, CFSTR("org.finch.test.cfnotify.dist"), CFSTR("sender"),
                                             (__bridge CFDictionaryRef) @{@"k" : @2}, true);
        printf("posted\n");
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
        printf("end\n");
    }
    return 0;
}
