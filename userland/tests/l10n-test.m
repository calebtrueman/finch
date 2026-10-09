/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-l10n-test: bundle localization. Picking localizations for a list of
 * preferred languages, and strings from .lproj tables and from a .loctable
 * (the single property list of every localization that macOS apps ship),
 * in a bundle the test writes to a temporary directory. Prints everything;
 * run it against Apple's CoreFoundation and Finch's (DYLD_FRAMEWORK_PATH) and diff.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>

/* CoreFoundation exports it; the SDK headers don't declare it. */
extern CFStringRef CFBundleCopyLocalizedStringForLocalization(CFBundleRef, CFStringRef key, CFStringRef value,
                                                              CFStringRef table, CFStringRef localization);

static void
write_plist(id plist, NSString *path)
{
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:plist
                                                           format:NSPropertyListBinaryFormat_v1_0
                                                          options:0
                                                            error:NULL];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    [d writeToFile:path atomically:YES];
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        Dl_info dl;
        dladdr((void *)CFBundleCopyPreferredLocalizationsFromArray, &dl);
        printf("%s\n", dl.dli_fname);

        NSArray *available = @[ @"de", @"ko", @"en_AU", @"en", @"fr", @"fr_CA", @"zh_CN", @"zh_TW", @"pt_BR", @"Base" ];
        NSArray *prefs = @[
            @[ @"en-CA", @"fr-CA" ], @[ @"en" ], @[ @"en-AU" ], @[ @"en-GB" ], @[ @"fr-CA" ], @[ @"fr-BE" ],
            @[ @"zh-Hant-TW" ], @[ @"zh-Hans" ], @[ @"pt-PT" ], @[ @"ja", @"ko" ], @[ @"ja" ], @[]
        ];
        for (NSArray *p in prefs) {
            NSArray *r = CFBridgingRelease(
                CFBundleCopyLocalizationsForPreferences((__bridge CFArrayRef)available, (__bridge CFArrayRef)p));
            printf("prefer [%s]: %s\n", [p componentsJoinedByString:@","].UTF8String,
                   [r componentsJoinedByString:@","].UTF8String);
        }

        char tmpl[] = "/tmp/finch-l10n-test.XXXXXX";
        NSString *dir = @(mkdtemp(tmpl));
        NSString *bundlePath = [dir stringByAppendingPathComponent:@"Test.bundle"];
        NSString *res = [bundlePath stringByAppendingPathComponent:@"Contents/Resources"];
        write_plist(@{@"CFBundleIdentifier" : @"org.finch.l10n-test", @"CFBundleDevelopmentRegion" : @"en"},
                    [bundlePath stringByAppendingPathComponent:@"Contents/Info.plist"]);
        write_plist(@{@"greeting" : @"Hello", @"only.strings" : @"from strings"},
                    [res stringByAppendingPathComponent:@"en.lproj/Localizable.strings"]);
        write_plist(@{@"greeting" : @"Bonjour"}, [res stringByAppendingPathComponent:@"fr.lproj/Localizable.strings"]);
        write_plist(
            @{
                @"en" : @{@"title" : @"Window", @"close" : @"Close"},
                @"fr" : @{@"title" : @"Fenêtre"},
                @"de" : @{@"title" : @"Fenster"},
                @"LocProvenance" : @{@"en" : @1, @"fr" : @1, @"de" : @1},
            },
            [res stringByAppendingPathComponent:@"Main.loctable"]);

        NSBundle *b = [NSBundle bundleWithPath:bundlePath];
        printf("localizations %s\n",
               [[[b localizations] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String);
        printf("preferred %s\n", [[b preferredLocalizations] componentsJoinedByString:@","].UTF8String);
        for (NSString *table in @[ @"Localizable", @"Main", @"Missing" ])
            for (NSString *key in @[ @"greeting", @"only.strings", @"title", @"close", @"absent" ])
                printf("%s/%s: %s\n", table.UTF8String, key.UTF8String,
                       [[b localizedStringForKey:key value:@"(default)" table:table] UTF8String]);
        CFBundleRef cf = CFBundleCreate(NULL, (__bridge CFURLRef)[NSURL fileURLWithPath:bundlePath]);
        for (NSString *loc in @[ @"fr", @"de", @"en", @"ko" ]) {
            NSString *s = CFBridgingRelease(CFBundleCopyLocalizedStringForLocalization(
                cf, CFSTR("title"), CFSTR("(default)"), CFSTR("Main"), (__bridge CFStringRef)loc));
            NSString *g = CFBridgingRelease(CFBundleCopyLocalizedStringForLocalization(
                cf, CFSTR("greeting"), CFSTR("(default)"), NULL, (__bridge CFStringRef)loc));
            printf("for %s: %s %s\n", loc.UTF8String, s.UTF8String, g.UTF8String);
        }
        CFRelease(cf);
        [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
    }
    return 0;
}
