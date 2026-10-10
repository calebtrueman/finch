/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-files-test: NSURL, NSURLComponents, NSFileManager and NSBundle,
 * one result per line so runs against Apple's Foundation and Finch's can be
 * diffed. Works in a scratch directory it makes and removes; paths are
 * printed relative to it.
 */
#import <Foundation/Foundation.h>
#include <string.h>
#include <unistd.h>

static NSString *root;

static const char *
rel(NSString *path)
{
    NSString *r = [root stringByResolvingSymlinksInPath];
    NSString *p = [path stringByResolvingSymlinksInPath];
    if ([p hasPrefix:r]) p = [@"<root>" stringByAppendingString:[p substringFromIndex:r.length]];
    return p.UTF8String;
}

static void
err(const char *what, NSError *e)
{
    printf("%s: %s %ld\n", what, e ? e.domain.UTF8String : "(no error)", (long)e.code);
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        /* URLs */
        NSURL *u = [NSURL URLWithString:@"https://user:pw@example.com:8443/a/b/c.txt?q=1&r=2#frag"];
        printf("bridged: %d\n", CFGetTypeID((__bridge CFTypeRef)u) == CFURLGetTypeID());
        printf("parts: %s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", u.scheme.UTF8String, u.host.UTF8String, u.port.description.UTF8String,
            u.user.UTF8String, u.password.UTF8String, u.path.UTF8String, u.query.UTF8String, u.fragment.UTF8String,
            u.lastPathComponent.UTF8String, u.pathExtension.UTF8String, [u.pathComponents componentsJoinedByString:@","].UTF8String);
        NSURL *r = [NSURL URLWithString:@"../d/e.html?x" relativeToURL:u];
        printf("relative: %s | %s | %s | %s\n", r.relativeString.UTF8String, r.absoluteString.UTF8String, r.description.UTF8String, r.relativePath.UTF8String);
        NSURL *f = [NSURL fileURLWithPath:@"/tmp/some dir/file.txt"];
        printf("file: %s %s %d %s\n", f.absoluteString.UTF8String, f.path.UTF8String, f.isFileURL, f.fileSystemRepresentation);
        NSURL *d = [NSURL fileURLWithPath:@"/tmp" isDirectory:YES];
        printf("directory: %s %d\n", d.absoluteString.UTF8String, d.hasDirectoryPath);
        printf("appending: %s | %s\n", [d URLByAppendingPathComponent:@"x y" isDirectory:NO].absoluteString.UTF8String,
            [d URLByAppendingPathComponent:@"sub" isDirectory:YES].absoluteString.UTF8String);
        printf("deleting: %s | %s | %s\n", f.URLByDeletingLastPathComponent.absoluteString.UTF8String,
            f.URLByDeletingPathExtension.absoluteString.UTF8String, [f URLByAppendingPathExtension:@"gz"].absoluteString.UTF8String);
        printf("standardized: %s\n", [NSURL URLWithString:@"http://h/a/./b/../c"].standardizedURL.absoluteString.UTF8String);
        printf("invalid: %s\n", [NSURL URLWithString:@"http://bad host/"] ? "url" : "nil");
        printf("equal: %d %d\n", [[NSURL URLWithString:@"http://x/y"] isEqual:[NSURL URLWithString:@"http://x/y"]],
            [[NSURL URLWithString:@"http://x/y"] isEqual:[NSURL URLWithString:@"http://x/z"]]);
        NSURLComponents *c = [NSURLComponents componentsWithString:@"https://ex.com/p?a=1&b=two%20words&flag"];
        for (NSURLQueryItem *q in c.queryItems) printf("query item: %s=%s\n", q.name.UTF8String, q.value ? q.value.UTF8String : "(nil)");
        c.path = @"/new path";
        c.queryItems = @[ [NSURLQueryItem queryItemWithName:@"k" value:@"v w"], [NSURLQueryItem queryItemWithName:@"e" value:nil] ];
        c.fragment = @"f g";
        printf("components: %s\n", c.URL.absoluteString.UTF8String);
        printf("percent-encoded path: %s\n", c.percentEncodedPath.UTF8String);
        printf("encode: %s | %s\n", [@"a b&c/é" stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet].UTF8String,
            [@"a b&c/é" stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet].UTF8String);
        printf("decode: %s\n", [@"a%20b%C3%A9" stringByRemovingPercentEncoding].UTF8String);

        /* Files */
        NSFileManager *fm = [NSFileManager defaultManager];
        char tmpl[] = "/tmp/finch-files-XXXXXX";
        root = [NSString stringWithUTF8String:mkdtemp(tmpl)];
        NSString *a = [root stringByAppendingPathComponent:@"a"], *nested = [root stringByAppendingPathComponent:@"x/y/z"];
        NSError *e = nil;
        printf("mkdir nested without intermediates: %d ", [fm createDirectoryAtPath:nested withIntermediateDirectories:NO attributes:nil error:&e]);
        err("error", e);
        e = nil;
        printf("mkdir nested: %d\n", [fm createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:&e]);
        printf("mkdir again with intermediates: %d\n", [fm createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:NULL]);
        printf("create file: %d\n", [fm createFileAtPath:a contents:[@"hello" dataUsingEncoding:NSUTF8StringEncoding] attributes:@{ NSFilePosixPermissions: @0640 }]);
        BOOL isDir = YES;
        printf("exists: %d dir %d | %d dir %d | %d\n", [fm fileExistsAtPath:a isDirectory:&isDir], isDir, [fm fileExistsAtPath:nested isDirectory:&isDir], isDir,
            [fm fileExistsAtPath:[root stringByAppendingPathComponent:@"none"]]);
        printf("readable %d writable %d executable %d\n", [fm isReadableFileAtPath:a], [fm isWritableFileAtPath:a], [fm isExecutableFileAtPath:a]);
        NSDictionary *attrs = [fm attributesOfItemAtPath:a error:NULL];
        printf("attributes: %s size %llu perms %o type %s owner-id-matches %d\n", [attrs[NSFileType] UTF8String], attrs.fileSize,
            (unsigned)attrs.filePosixPermissions, attrs.fileType.UTF8String, [attrs[NSFileOwnerAccountID] unsignedIntValue] == getuid());
        printf("contents: %s\n", [[NSString alloc] initWithData:[fm contentsAtPath:a] encoding:NSUTF8StringEncoding].UTF8String);
        [fm setAttributes:@{ NSFilePosixPermissions: @0600, NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:1000000000] } ofItemAtPath:a error:NULL];
        attrs = [fm attributesOfItemAtPath:a error:NULL];
        printf("set attributes: %o %.0f\n", (unsigned)attrs.filePosixPermissions, attrs.fileModificationDate.timeIntervalSince1970);
        NSString *b = [root stringByAppendingPathComponent:@"b"];
        printf("copy: %d equal %d\n", [fm copyItemAtPath:a toPath:b error:NULL], [fm contentsEqualAtPath:a andPath:b]);
        e = nil;
        printf("copy over existing: %d ", [fm copyItemAtPath:a toPath:b error:&e]);
        err("error", e);
        NSString *m = [root stringByAppendingPathComponent:@"x/moved"];
        printf("move: %d %d %d\n", [fm moveItemAtPath:b toPath:m error:NULL], [fm fileExistsAtPath:b], [fm fileExistsAtPath:m]);
        NSString *link = [root stringByAppendingPathComponent:@"link"];
        printf("symlink: %d -> %s\n", [fm createSymbolicLinkAtPath:link withDestinationPath:@"a" error:NULL],
            [fm destinationOfSymbolicLinkAtPath:link error:NULL].UTF8String);
        printf("symlink type: %s\n", [[fm attributesOfItemAtPath:link error:NULL][NSFileType] UTF8String]);
        NSArray *contents = [[fm contentsOfDirectoryAtPath:root error:NULL] sortedArrayUsingSelector:@selector(compare:)];
        printf("contents: %s\n", [contents componentsJoinedByString:@" "].UTF8String);
        NSArray *sub = [[fm subpathsOfDirectoryAtPath:root error:NULL] sortedArrayUsingSelector:@selector(compare:)];
        printf("subpaths: %s\n", [sub componentsJoinedByString:@" "].UTF8String);
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
        NSMutableArray *seen = [NSMutableArray array];
        for (NSString *p in en) {
            [seen addObject:p];
            if ([p isEqualToString:@"x"]) [en skipDescendants];
        }
        printf("enumerator skipping x: %s\n", [[seen sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "].UTF8String);
        NSArray *urls = [fm contentsOfDirectoryAtURL:[NSURL fileURLWithPath:root] includingPropertiesForKeys:nil
                                             options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL];
        NSMutableArray *names = [NSMutableArray array];
        for (NSURL *x in urls) [names addObject:[x.lastPathComponent stringByAppendingString:x.hasDirectoryPath ? @"/" : @""]];
        printf("URL contents: %s\n", [[names sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "].UTF8String);
        e = nil;
        printf("contents of missing dir: %s ", [fm contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:@"missing"] error:&e] ? "array" : "nil");
        err("error", e);
        e = nil;
        printf("attributes of missing: %s ", [fm attributesOfItemAtPath:[root stringByAppendingPathComponent:@"missing"] error:&e] ? "dict" : "nil");
        err("error", e);
        printf("current directory changes: %d %s\n", [fm changeCurrentDirectoryPath:root], rel(fm.currentDirectoryPath));
        NSURL *rf = [NSURL fileURLWithPath:@"a"];
        printf("relative file URL resolves: %s\n", rel(rf.path));
        printf("resolving symlinks: %s\n", rel([link stringByResolvingSymlinksInPath]));
        e = nil;
        printf("remove: %d %d\n", [fm removeItemAtPath:[root stringByAppendingPathComponent:@"x"] error:&e], [fm fileExistsAtPath:nested]);
        e = nil;
        printf("remove missing: %d ", [fm removeItemAtPath:[root stringByAppendingPathComponent:@"x"] error:&e]);
        err("error", e);

        /* Bookmarks: made, resolved (also relative to a folder), their resource values */
        {
            NSString *target = [root stringByAppendingPathComponent:@"bookmarked.txt"];
            [@"b" writeToFile:target atomically:NO encoding:NSUTF8StringEncoding error:NULL];
            NSURL *u = [NSURL fileURLWithPath:target];
            NSError *be = nil;
            NSData *bm = [u bookmarkDataWithOptions:0 includingResourceValuesForKeys:@[ NSURLLocalizedNameKey ] relativeToURL:nil error:&be];
            BOOL stale = YES;
            NSURL *back = [NSURL URLByResolvingBookmarkData:bm options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil
                                        bookmarkDataIsStale:&stale error:&be];
            printf("bookmark: made %d, resolves to %s, stale %d\n", bm != nil, [back.path.lastPathComponent UTF8String], stale);
            NSDictionary *vals = [NSURL resourceValuesForKeys:@[ NSURLNameKey, NSURLLocalizedNameKey ] fromBookmarkData:bm];
            printf("bookmark values: %s %s\n", [vals[NSURLNameKey] UTF8String], [vals[NSURLLocalizedNameKey] UTF8String]);
            NSURL *base = [NSURL fileURLWithPath:root isDirectory:YES];
            NSData *rel = [u bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:base error:&be];
            back = [NSURL URLByResolvingBookmarkData:rel options:NSURLBookmarkResolutionWithoutUI relativeToURL:base
                                 bookmarkDataIsStale:&stale error:&be];
            printf("relative bookmark resolves to %s\n", [back.path.lastPathComponent UTF8String]);
            be = nil;
            NSData *none = [[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"nothing-here"]]
                bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&be];
            printf("bookmark of a missing file: %d error %s %ld\n", none != nil, be.domain.UTF8String, (long)be.code);
            [fm removeItemAtPath:target error:NULL];
            be = nil;
            back = [NSURL URLByResolvingBookmarkData:bm options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil
                                 bookmarkDataIsStale:&stale error:&be];
            printf("bookmark of a removed file: %d error %s %ld\n", back != nil, be.domain.UTF8String, (long)be.code);
        }

        /* Search paths */
        NSString *home = NSHomeDirectory();
        for (NSNumber *dir in @[ @(NSDocumentDirectory), @(NSLibraryDirectory), @(NSCachesDirectory), @(NSApplicationSupportDirectory), @(NSApplicationDirectory) ]) {
            NSArray *paths = NSSearchPathForDirectoriesInDomains(dir.unsignedIntegerValue, NSAllDomainsMask, YES);
            NSMutableArray *shown = [NSMutableArray array];
            for (NSString *p in paths) [shown addObject:[p hasPrefix:home] ? [@"~" stringByAppendingString:[p substringFromIndex:home.length]] : p];
            printf("search path %lu: %s\n", (unsigned long)dir.unsignedIntegerValue, [shown componentsJoinedByString:@" "].UTF8String);
        }
        for (NSString *tail in @[ @"", @"/Docs/a.txt", @"x/y", @"/", @"//b/" ])
            printf("abbreviated home%s: %s\n", tail.UTF8String,
                   [[[home stringByAppendingString:tail] stringByAbbreviatingWithTildeInPath] stringByReplacingOccurrencesOfString:home withString:@"$HOME"].UTF8String);
        printf("abbreviated /tmp/x: %s, ~/a: %s\n", [@"/tmp/x" stringByAbbreviatingWithTildeInPath].UTF8String,
               [@"~/a" stringByAbbreviatingWithTildeInPath].UTF8String);
        printf("unexpanded: %s\n", [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, NO).firstObject UTF8String]);
        NSURL *caches = [fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        printf("caches URL is directory: %d ends %s\n", caches.hasDirectoryPath, caches.lastPathComponent.UTF8String);

        /* Bundles */
        NSString *bp = [root stringByAppendingPathComponent:@"Test.bundle"];
        [fm createDirectoryAtPath:[bp stringByAppendingPathComponent:@"Contents/Resources/en.lproj"] withIntermediateDirectories:YES attributes:nil error:NULL];
        NSDictionary *info = @{ @"CFBundleIdentifier": @"org.finch.test.bundle", @"CFBundleName": @"Test", @"CFBundleVersion": @"7",
            @"CFBundleDevelopmentRegion": @"en", @"Custom": @[ @1, @"two" ] };
        [[NSPropertyListSerialization dataWithPropertyList:info format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL]
            writeToFile:[bp stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES];
        [@"resource" writeToFile:[bp stringByAppendingPathComponent:@"Contents/Resources/thing.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [@"\"greeting\" = \"hello from strings\";\n" writeToFile:[bp stringByAppendingPathComponent:@"Contents/Resources/en.lproj/Localizable.strings"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSBundle *bundle = [NSBundle bundleWithPath:bp];
        printf("bundle: %s %s same object %d\n", bundle.bundleIdentifier.UTF8String, rel(bundle.bundlePath), bundle == [NSBundle bundleWithPath:bp]);
        printf("info: %s %s %s\n", [bundle.infoDictionary[@"CFBundleName"] UTF8String], [[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String],
            [[bundle.infoDictionary[@"Custom"] description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
        printf("resource: %s\n", rel([bundle pathForResource:@"thing" ofType:@"txt"]));
        printf("resource URL: %s\n", rel([bundle URLForResource:@"thing" withExtension:@"txt"].path));
        printf("missing resource: %s\n", [bundle pathForResource:@"nope" ofType:@"txt"] ? "found" : "nil");
        printf("resources of type: %lu\n", (unsigned long)[bundle pathsForResourcesOfType:@"txt" inDirectory:nil].count);
        printf("localized: %s | %s\n", [bundle localizedStringForKey:@"greeting" value:@"default" table:nil].UTF8String,
            [bundle localizedStringForKey:@"missing" value:@"default" table:nil].UTF8String);
        printf("localizations: %s development %s\n", [bundle.localizations componentsJoinedByString:@","].UTF8String, bundle.developmentLocalization.UTF8String);
        printf("bundleWithIdentifier: %d\n", [NSBundle bundleWithIdentifier:@"org.finch.test.bundle"] == bundle);
        printf("main bundle: %d foundation bundle id %s\n", [NSBundle mainBundle] != nil, [NSBundle bundleForClass:[NSString class]].bundleIdentifier.UTF8String);
        printf("not a bundle: %s\n", [NSBundle bundleWithPath:[root stringByAppendingPathComponent:@"nothing"]] ? "bundle" : "nil");

        [fm changeCurrentDirectoryPath:@"/"];
        printf("cleanup: %d\n", [fm removeItemAtPath:root error:NULL]);
    }
    printf("done\n");
    return 0;
}
