/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-uti-test: UniformTypeIdentifiers and NSURL's resource values. Every
 * core type constant, lookups by extension and MIME type, dynamic types,
 * conformance, tags, the NSString/NSURL additions, and the resource values
 * of files of each kind. Prints everything; run it against Apple's
 * frameworks and Finch's (DYLD_FRAMEWORK_PATH) and diff.
 */
#import <Foundation/Foundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#include <sys/stat.h>

static NSString *
ids(id<NSFastEnumeration> types)
{
    NSMutableArray *a = [NSMutableArray array];
    for (UTType *t in types)
        [a addObject:t.identifier];
    [a sortUsingSelector:@selector(compare:)];
    return [a componentsJoinedByString:@","];
}

static void
show(const char *label, UTType *t)
{
    if (!t) {
        printf("%s: nil\n", label);
        return;
    }
    printf("%s: %s desc '%s' ext %s mime %s dyn %d decl %d public %d supers %s\n", label, t.identifier.UTF8String,
           t.localizedDescription.UTF8String ?: "", t.preferredFilenameExtension.UTF8String ?: "-",
           t.preferredMIMEType.UTF8String ?: "-", t.isDynamic, t.isDeclared, t.isPublicType,
           ids(t.supertypes).UTF8String);
}

static void
types(void)
{
    printf("== core types\n");
#define X(name) show(#name, name);
#include "uti-constants.inc"
#undef X
    printf("== lookups\n");
    for (NSString *e in @[ @"txt", @"TXT", @"rtf", @"html", @"png", @"jpg", @"jpeg", @"md", @"json", @"swift", @"c",
                           @"h", @"zip", @"app", @"pdf", @"mp3", @"zzqq", @"a", @"abcd", @"xyz123", @"z:z=q?" ]) {
        UTType *t = [UTType typeWithFilenameExtension:e];
        printf("ext %s -> %s tags %s\n", e.UTF8String, t.identifier.UTF8String,
               [[(t.tags[UTTagClassFilenameExtension] ?: @[]) componentsJoinedByString:@","] UTF8String]);
    }
    for (NSString *m in @[ @"text/plain", @"text/html", @"image/png", @"application/json", @"text/x-zzqq",
                           @"application/x-foo" ])
        printf("mime %s -> %s\n", m.UTF8String, [UTType typeWithMIMEType:m].identifier.UTF8String);
    printf("txt as image %s\n", [UTType typeWithFilenameExtension:@"txt" conformingToType:UTTypeImage].identifier.UTF8String);
    printf("zzqq as json %s\n", [UTType typeWithFilenameExtension:@"zzqq" conformingToType:UTTypeJSON].identifier.UTF8String);
    printf("jpg types %s\n", ids([UTType typesWithTag:@"jpg" tagClass:UTTagClassFilenameExtension conformingToType:nil]).UTF8String);
    UTType *d = [UTType typeWithIdentifier:@"dyn.ah62d4rv4ge81y8xvse"];
    show("decoded dynamic", d);
    printf("dynamic tags %s conforms data %d text %d\n",
           [(d.tags[UTTagClassFilenameExtension] ?: @[]) componentsJoinedByString:@","].UTF8String,
           [d conformsToType:UTTypeData], [d conformsToType:UTTypeText]);
    show("unknown", [UTType typeWithIdentifier:@"com.example.unknown"]);
    UTType *c = [UTType typeWithIdentifier:@"PUBLIC.PLAIN-TEXT"];
    printf("case: %s equal %d hash %d\n", c.identifier.UTF8String, [c isEqual:UTTypePlainText],
           c.hash == UTTypePlainText.hash);
    printf("conforms %d %d %d %d super %d sub %d\n", [UTTypePlainText conformsToType:UTTypeText],
           [UTTypeText conformsToType:UTTypePlainText], [UTTypePlainText conformsToType:UTTypePlainText],
           [UTTypePlainText conformsToType:UTTypeData], [UTTypeText isSupertypeOfType:UTTypePlainText],
           [UTTypeText isSubtypeOfType:UTTypePlainText]);
    printf("description %s\n", UTTypePlainText.description.UTF8String);
    printf("additions %s %s %s\n", [@"/a" stringByAppendingPathComponent:@"b" conformingToType:UTTypePlainText].UTF8String,
           [@"/a" stringByAppendingPathComponent:@"b.txt" conformingToType:UTTypePlainText].UTF8String,
           [@"/a/b" stringByAppendingPathExtensionForType:UTTypePNG].UTF8String);
    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:UTTypePNG requiringSecureCoding:YES error:NULL];
    UTType *back = [NSKeyedUnarchiver unarchivedObjectOfClass:[UTType class] fromData:archived error:NULL];
    printf("archived %s\n", back.identifier.UTF8String);
}

static void
resources(NSString *base)
{
    printf("== resource values\n");
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[base stringByAppendingPathComponent:@"dir"] withIntermediateDirectories:YES
                   attributes:nil error:NULL];
    /* the real path: the temporary directory may be behind a symbolic link (/var -> /private/var) */
    char real[PATH_MAX];
    if (realpath([base fileSystemRepresentation], real))
        base = @(real);
    [fm createDirectoryAtPath:[base stringByAppendingPathComponent:@"B.app/Contents"] withIntermediateDirectories:YES
                   attributes:nil error:NULL];
    [@"hello\n" writeToFile:[base stringByAppendingPathComponent:@"a.txt"] atomically:NO encoding:NSUTF8StringEncoding
                      error:NULL];
    chmod([[base stringByAppendingPathComponent:@"a.txt"] fileSystemRepresentation], 0600);
    [@"x\n" writeToFile:[base stringByAppendingPathComponent:@".hidden"] atomically:NO encoding:NSUTF8StringEncoding
                  error:NULL];
    [fm createSymbolicLinkAtPath:[base stringByAppendingPathComponent:@"link"] withDestinationPath:@"a.txt" error:NULL];
    NSArray *keys = @[
        NSURLNameKey, NSURLLocalizedNameKey, NSURLIsRegularFileKey, NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey,
        NSURLIsVolumeKey, NSURLIsPackageKey, NSURLIsApplicationKey, NSURLIsHiddenKey, NSURLIsReadableKey,
        NSURLIsWritableKey, NSURLIsExecutableKey, NSURLFileSizeKey, NSURLLinkCountKey, NSURLFileResourceTypeKey,
        NSURLParentDirectoryURLKey, NSURLPathKey, NSURLTypeIdentifierKey, NSURLHasHiddenExtensionKey,
        NSURLIsAliasFileKey, NSURLLabelNumberKey, NSURLIsUserImmutableKey, NSURLIsSystemImmutableKey,
        NSURLIsExcludedFromBackupKey, NSURLIsUbiquitousItemKey, NSURLTotalFileSizeKey, NSURLIsMountTriggerKey,
        NSURLLocalizedTypeDescriptionKey, @"bogusKey"
    ];
    for (NSString *n in @[ @"a.txt", @"dir", @"B.app", @".hidden", @"link", @"missing" ]) {
        NSURL *u = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:n]];
        printf("%s:\n", n.UTF8String);
        for (NSString *k in keys) {
            id v = nil;
            NSError *e = nil;
            BOOL ok = [u getResourceValue:&v forKey:k error:&e];
            NSString *s = [v isKindOfClass:[NSURL class]] ? [v path] : [v description];
            s = [s stringByReplacingOccurrencesOfString:base withString:@"BASE"];
            printf("  %s: %d %s%s\n", k.UTF8String, ok, s.UTF8String ?: "nil",
                   e ? [NSString stringWithFormat:@" error %@ %ld", e.domain, (long)e.code].UTF8String : "");
        }
        NSError *e = nil;
        NSDictionary *dict = [u resourceValuesForKeys:@[ NSURLNameKey, NSURLIsDirectoryKey, @"bogusKey" ] error:&e];
        printf("  dict %s error %ld\n",
               [[dict.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String,
               (long)e.code);
    }
    id v = nil;
    NSError *e = nil;
    printf("web: %d %s %ld\n", [[NSURL URLWithString:@"http://x/y"] getResourceValue:&v forKey:NSURLNameKey error:&e],
           [v description].UTF8String ?: "nil", (long)e.code);
    NSURL *t = [NSURL fileURLWithPath:[base stringByAppendingPathComponent:@"a.txt"]];
    UTType *ct = nil;
    [t getResourceValue:&ct forKey:NSURLContentTypeKey error:NULL];
    printf("content type %s\n", ct.identifier.UTF8String);
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", class_getImageName([UTType class]));
        types();
        NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:@"finch-uti-test"];
        resources(base);
    }
    return 0;
}
