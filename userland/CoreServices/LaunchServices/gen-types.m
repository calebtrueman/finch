/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Host tool (macOS only, not part of Finch): writes UTTypeTable.inc, the
 * system-declared types the UTType C API knows, with their tags in all four
 * classes (filename extension, MIME type, OSType, NSPasteboard type). The
 * types are UniformTypeIdentifiers' (userland/UniformTypeIdentifiers/
 * UTTypeTable.inc), LaunchServices' kUTType constants, every declared type
 * that shares one of their tags, and the supertypes of all of those.
 *
 *   xcrun clang -fobjc-arc gen-types.m -framework CoreServices -framework Foundation -o gen
 *   ./gen ../../UniformTypeIdentifiers/UTTypeTable.inc ../../tests/coreservices-uttypes.inc > UTTypeTable.inc
 */
#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSString *
q(NSString *s)
{
    return [NSString stringWithFormat:@"\"%@\"", [[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                                                   stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
}

static NSArray *
tags(NSString *t, CFStringRef cls)
{
    return CFBridgingRelease(UTTypeCopyAllTagsWithClass((__bridge CFStringRef)t, cls)) ?: @[];
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        NSMutableOrderedSet *types = [NSMutableOrderedSet orderedSet];
        NSString *uti = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [uti componentsSeparatedByString:@"\n"]) {
            NSRange r = [line rangeOfString:@"{\""];
            if (r.location == NSNotFound)
                continue;
            NSString *rest = [line substringFromIndex:NSMaxRange(r)];
            [types addObject:[rest substringToIndex:[rest rangeOfString:@"\""].location]];
        }
        NSString *consts = [NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [consts componentsSeparatedByString:@"\n"]) {
            NSRange r = [line rangeOfString:@"X(kUTType"];
            if (r.location == NSNotFound)
                continue;
            NSString *name = [[line substringFromIndex:r.location + 2] stringByReplacingOccurrencesOfString:@")" withString:@""];
            CFStringRef *p = dlsym(RTLD_DEFAULT, name.UTF8String);
            if (p && *p && UTTypeIsDeclared(*p))
                [types addObject:(__bridge NSString *)*p];
        }
        CFStringRef classes[] = {kUTTagClassFilenameExtension, kUTTagClassMIMEType, kUTTagClassOSType, kUTTagClassNSPboardType};
        /* and those common OSTypes and pasteboard types name */
        NSArray *seeds[4] = {
            @[], @[],
            [@"TEXT utxt ut16 utf8 PDF  JPEG PNGf TIFF GIFf BMP  BMPf ICO  icns APPL APPC fold disk MooV MPG3 AIFF WAVE "
              @"RTF  RTFD HTML PICT 8BPS TPIC ZIP  sbFl ttro clpt clpp" componentsSeparatedByString:@" "],
            [@"NSStringPboardType NSFilenamesPboardType NSTIFFPboardType NSPDFPboardType NSRTFPboardType "
              @"NSRTFDPboardType NSHTMLPboardType NSURLPboardType NSColorPboardType NSFontPboardType NSRulerPboardType "
              @"NSTabularTextPboardType NSVCardPboardType NSFilesPromisePboardType NSPICTPboardType" componentsSeparatedByString:@" "],
        };
        for (int c = 2; c < 4; c++)
            for (NSString *tag in seeds[c]) {
                NSString *t = c == 2 && tag.length == 3 ? [tag stringByAppendingString:@" "] : tag;
                NSArray *all = CFBridgingRelease(UTTypeCreateAllIdentifiersForTag(classes[c], (__bridge CFStringRef)t, NULL));
                for (NSString *o in all)
                    if (UTTypeIsDeclared((__bridge CFStringRef)o))
                        [types addObject:o];
            }
        /* types sharing a tag, then supertypes, until nothing new */
        for (NSUInteger i = 0; i < types.count; i++) {
            NSString *t = types[i];
            for (int c = 0; c < 4; c++)
                for (NSString *tag in tags(t, classes[c])) {
                    NSArray *all = CFBridgingRelease(UTTypeCreateAllIdentifiersForTag(classes[c], (__bridge CFStringRef)tag, NULL));
                    for (NSString *o in all)
                        if (UTTypeIsDeclared((__bridge CFStringRef)o) && ![o hasPrefix:@"dyn."])
                            [types addObject:o];
                }
            NSDictionary *decl = CFBridgingRelease(UTTypeCopyDeclaration((__bridge CFStringRef)t));
            id conf = decl[(__bridge NSString *)kUTTypeConformsToKey];
            for (NSString *p in [conf isKindOfClass:[NSString class]] ? @[ conf ] : conf)
                if ([p isKindOfClass:[NSString class]] && UTTypeIsDeclared((__bridge CFStringRef)p))
                    [types addObject:p];
        }
        printf("/* SPDX-License-Identifier: MIT OR Apache-2.0 */\n");
        printf("/*\n * The system-declared types the UTType C API knows: identifier, description, direct\n"
               " * parents, filename extensions, MIME types, OSTypes and NSPasteboard types (each list\n"
               " * space-separated, preferred first; a space within a tag written \\001). Facts about\n"
               " * macOS 26.4's type declarations, generated by gen-types.m (see its comment).\n */\n");
        for (NSString *t in types) {
            NSDictionary *decl = CFBridgingRelease(UTTypeCopyDeclaration((__bridge CFStringRef)t));
            id conf = decl[(__bridge NSString *)kUTTypeConformsToKey];
            NSArray *parents = [conf isKindOfClass:[NSString class]] ? @[ conf ] : (conf ?: @[]);
            NSString *desc = CFBridgingRelease(UTTypeCopyDescription((__bridge CFStringRef)t));
            NSMutableArray *cols = [NSMutableArray array];
            for (int c = 0; c < 4; c++) {
                NSMutableArray *a = [NSMutableArray array];
                for (NSString *tag in tags(t, classes[c]))
                    [a addObject:[tag stringByReplacingOccurrencesOfString:@" " withString:@"\x01"]];
                [cols addObject:[q([a componentsJoinedByString:@" "]) stringByReplacingOccurrencesOfString:@"\x01" withString:@"\\001"]];
            }
            printf("    {%s, %s, %s, %s},\n", q(t).UTF8String, desc ? q(desc).UTF8String : "NULL",
                   q([parents componentsJoinedByString:@" "]).UTF8String, [cols componentsJoinedByString:@", "].UTF8String);
        }
    }
    return 0;
}
