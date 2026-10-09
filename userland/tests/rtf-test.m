/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-rtf-test: NSAttributedString's document formats. Writes RTF for
 * attributed strings of each kind (fonts, colours, underline, links,
 * paragraph styles, document attributes, special characters), reads RTF
 * documents (as Apple's writer makes them, and hand-written ones), and
 * round-trips RTFD and plain text. Prints everything; run it against Apple's
 * frameworks and Finch's (DYLD_FRAMEWORK_PATH) and diff all but the first line.
 * Fonts are printed by size and traits, since Finch's fonts are its own.
 */
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <stdio.h>

static void
show_color(const char *label, NSColor *c)
{
    if (!c)
        return;
    NSColor *s = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    printf(" %s=%.2f,%.2f,%.2f", label, s.redComponent, s.greenComponent, s.blueComponent);
}

static void
show_runs(NSAttributedString *s)
{
    printf("  length %lu: \"", (unsigned long)s.length);
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s.string characterAtIndex:i];
        if (c == '\n')
            printf("\\n");
        else if (c == '\t')
            printf("\\t");
        else if (c < 0x80 && c >= 0x20)
            printf("%c", c);
        else
            printf("<%04x>", c);
    }
    printf("\"\n");
    [s enumerateAttributesInRange:NSMakeRange(0, s.length) options:0
                       usingBlock:^(NSDictionary *a, NSRange r, BOOL *stop) {
                           printf("  [%lu,%lu]", (unsigned long)r.location, (unsigned long)r.length);
                           NSFont *f = a[NSFontAttributeName];
                           if (f) {
                               NSFontTraitMask t = [[NSFontManager sharedFontManager] traitsOfFont:f];
                               printf(" font %g%s%s%s", f.pointSize, (t & NSBoldFontMask) ? " bold" : "",
                                      (t & NSItalicFontMask) ? " italic" : "", f.isFixedPitch ? " fixed" : "");
                           }
                           show_color("fg", a[NSForegroundColorAttributeName]);
                           show_color("bg", a[NSBackgroundColorAttributeName]);
                           for (NSString *k in @[ NSUnderlineStyleAttributeName, NSStrikethroughStyleAttributeName,
                                                  NSSuperscriptAttributeName, NSBaselineOffsetAttributeName,
                                                  NSKernAttributeName ])
                               if (a[k])
                                   printf(" %s=%g", k.UTF8String, [a[k] doubleValue]);
                           if (a[NSLinkAttributeName])
                               printf(" link=%s", [[a[NSLinkAttributeName] description] UTF8String]);
                           if (a[NSAttachmentAttributeName]) {
                               NSFileWrapper *w = [a[NSAttachmentAttributeName] fileWrapper];
                               printf(" attachment=%s(%lu bytes)", w.preferredFilename.UTF8String,
                                      (unsigned long)w.regularFileContents.length);
                           }
                           NSParagraphStyle *p = a[NSParagraphStyleAttributeName];
                           if (p)
                               printf(" para(align %ld head %g first %g tail %g before %g after %g mult %g min %g max "
                                      "%g spacing %g tabs %lu)",
                                      (long)p.alignment, p.headIndent, p.firstLineHeadIndent, p.tailIndent,
                                      p.paragraphSpacingBefore, p.paragraphSpacing, p.lineHeightMultiple,
                                      p.minimumLineHeight, p.maximumLineHeight, p.lineSpacing,
                                      (unsigned long)p.tabStops.count);
                           printf("\n");
                       }];
}

static void
show_doc(NSDictionary *d)
{
    for (NSString *k in [[d allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        id v = d[k];
        if ([v isKindOfClass:[NSValue class]] && strcmp([v objCType], @encode(NSSize)) == 0)
            printf("  doc %s = %s\n", k.UTF8String, NSStringFromSize([v sizeValue]).UTF8String);
        else if ([v isKindOfClass:[NSColor class]])
            show_color([k UTF8String], v), printf("\n");
        else
            printf("  doc %s = %s\n", k.UTF8String, [[v description] UTF8String]);
    }
}

static NSMutableAttributedString *
str(NSString *s, NSFont *f)
{
    return [[NSMutableAttributedString alloc] initWithString:s attributes:f ? @{NSFontAttributeName : f} : @{}];
}

static void
write_case(const char *label, NSAttributedString *s, NSDictionary *doc)
{
    NSData *d = [s RTFFromRange:NSMakeRange(0, s.length) documentAttributes:doc ?: @{}];
    NSString *text = [[NSString alloc] initWithData:d encoding:NSASCIIStringEncoding];
    /* the colour table's Generic RGB values come from Apple's colour profiles: compared as \cssrgb only */
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"])
        [lines addObject:[line hasPrefix:@"{\\colortbl"] ? @"{\\colortbl...}" : line];
    printf("== write %s\n%s\n", label, [[lines componentsJoinedByString:@"\n"] UTF8String]);
    NSDictionary *back = nil;
    NSAttributedString *r = [[NSAttributedString alloc] initWithRTF:d documentAttributes:&back];
    printf("-- read back\n");
    show_runs(r);
}

static void
read_case(const char *label, const char *rtf)
{
    NSData *d = [NSData dataWithBytes:rtf length:strlen(rtf)];
    NSDictionary *doc = nil;
    NSError *e = nil;
    NSAttributedString *s = [[NSAttributedString alloc] initWithData:d options:@{} documentAttributes:&doc error:&e];
    printf("== read %s: %s\n", label, s ? "ok" : "failed");
    if (s) {
        show_runs(s);
        show_doc(doc);
    }
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        Dl_info dl;
        dladdr((__bridge void *)[NSParagraphStyle class], &dl);
        printf("%s\n", dl.dli_fname);
        [NSApplication sharedApplication];
        NSFont *helv = [NSFont fontWithName:@"Helvetica" size:12];

        write_case("plain", str(@"plain", nil), nil);
        write_case("empty", str(@"", nil), nil);
        NSMutableAttributedString *s = str(@"Hello bold italic red\nCentered line\tTab \u00e9 \u00fc \u4e2d\u6587\n", helv);
        [s addAttribute:NSFontAttributeName value:[NSFont fontWithName:@"Helvetica-Bold" size:12] range:NSMakeRange(6, 4)];
        [s addAttribute:NSFontAttributeName value:[NSFont fontWithName:@"Helvetica-Oblique" size:14] range:NSMakeRange(11, 6)];
        [s addAttribute:NSForegroundColorAttributeName value:[NSColor colorWithSRGBRed:1 green:0 blue:0 alpha:1]
                  range:NSMakeRange(18, 3)];
        [s addAttribute:NSUnderlineStyleAttributeName value:@1 range:NSMakeRange(0, 5)];
        NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
        center.alignment = NSTextAlignmentCenter;
        [s addAttribute:NSParagraphStyleAttributeName value:center range:NSMakeRange(22, s.length - 22)];
        write_case("mixed", s, nil);
        NSMutableAttributedString *fonts = str(@"tttccmmm", [NSFont fontWithName:@"Times-Roman" size:13.5]);
        [fonts addAttribute:NSFontAttributeName value:[NSFont fontWithName:@"Courier" size:10] range:NSMakeRange(3, 2)];
        [fonts addAttribute:NSFontAttributeName value:[NSFont fontWithName:@"Menlo-Regular" size:11] range:NSMakeRange(5, 3)];
        write_case("fonts", fonts, nil);
        NSMutableAttributedString *a = str(@"strike super sub bg link kern", helv);
        [a addAttribute:NSStrikethroughStyleAttributeName value:@1 range:NSMakeRange(0, 6)];
        [a addAttribute:NSSuperscriptAttributeName value:@1 range:NSMakeRange(7, 5)];
        [a addAttribute:NSBaselineOffsetAttributeName value:@(-3) range:NSMakeRange(13, 3)];
        [a addAttribute:NSBackgroundColorAttributeName value:[NSColor colorWithSRGBRed:1 green:1 blue:0 alpha:1]
                  range:NSMakeRange(17, 2)];
        [a addAttribute:NSLinkAttributeName value:[NSURL URLWithString:@"https://example.com"] range:NSMakeRange(20, 4)];
        [a addAttribute:NSKernAttributeName value:@2 range:NSMakeRange(25, 4)];
        write_case("attributes", a, nil);
        NSMutableAttributedString *p = str(@"para one\npara two\n", helv);
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.firstLineHeadIndent = 20;
        ps.headIndent = 10;
        ps.tailIndent = -30;
        ps.paragraphSpacing = 6;
        ps.paragraphSpacingBefore = 4;
        ps.lineHeightMultiple = 1.5;
        ps.alignment = NSTextAlignmentRight;
        ps.tabStops = @[];
        [p addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, 9)];
        NSMutableParagraphStyle *ps2 = [[NSMutableParagraphStyle alloc] init];
        ps2.alignment = NSTextAlignmentJustified;
        ps2.minimumLineHeight = 20;
        ps2.maximumLineHeight = 20;
        ps2.lineSpacing = 3;
        [p addAttribute:NSParagraphStyleAttributeName value:ps2 range:NSMakeRange(9, 9)];
        write_case("paragraphs", p, nil);
        write_case("document", str(@"x", helv), @{
            NSLeftMarginDocumentAttribute : @72, NSRightMarginDocumentAttribute : @72,
            NSViewSizeDocumentAttribute : [NSValue valueWithSize:NSMakeSize(500, 400)], NSViewModeDocumentAttribute : @1,
            NSReadOnlyDocumentAttribute : @1, NSHyphenationFactorDocumentAttribute : @0.5,
            NSDefaultTabIntervalDocumentAttribute : @36, NSTitleDocumentAttribute : @"T", NSAuthorDocumentAttribute : @"A"
        });
        write_case("special", str(@"a{b}c\\d\u00a0e\u2014f\u2028g\fh", helv), nil);

        read_case("apple-mixed",
                  "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2869\n\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\fswiss\\fcharset0 "
                  "Helvetica;\\f1\\fswiss\\fcharset0 Helvetica-Bold;\\f2\\fswiss\\fcharset0 Helvetica-Oblique;\n}\n"
                  "{\\colortbl;\\red255\\green255\\blue255;\\red251\\green0\\blue7;}\n{\\*\\expandedcolortbl;;\\cssrgb\\c100000\\c0\\c0;}\n"
                  "\\pard\\tx560\\tx1120\\tx1680\\tx2240\\tx2800\\tx3360\\tx3920\\tx4480\\tx5040\\tx5600\\tx6160\\tx6720\\pardirnatural"
                  "\\partightenfactor0\n\n\\f0\\fs24 \\cf0 \\ul \\ulc0 Hello\\ulnone  \n\\f1\\b bold\n\\f0\\b0  \n\\f2\\i\\fs28 "
                  "italic\n\\f0\\i0\\fs24  \\cf2 red\\cf0 \\\n\\pard\\tx560\\pardirnatural\\qc\\partightenfactor0\n\\cf0 Centered "
                  "line\tTab \\'e9 \\'fc \\uc0\\u20013 \\u25991  \\u55357 \\u56832 \\\n}");
        read_case("apple-attributes",
                  "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2869\n\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0\\fswiss\\fcharset0 "
                  "Helvetica;}\n{\\colortbl;\\red255\\green255\\blue255;\\red255\\green255\\blue11;}\n{\\*\\expandedcolortbl;;"
                  "\\cssrgb\\c100000\\c100000\\c0;}\n\\pard\\pardirnatural\\partightenfactor0\n\n\\f0\\fs24 \\cf0 \\strike "
                  "\\strikec0 strike\\strike0\\striked0  \\super super\\nosupersub  \\dn6 sub\\up0  \\cb2 bg\\cb1  "
                  "{\\field{\\*\\fldinst{HYPERLINK \"https://example.com\"}}{\\fldrslt link}} \\kerning1\\expnd8\\expndtw40\nkern}");
        read_case("apple-paragraphs",
                  "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2869\n{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}\n{\\colortbl;"
                  "\\red255\\green255\\blue255;}\n\\pard\\li200\\fi200\\ri600\\sl360\\slmult1\\sb80\\sa120\\pardirnatural\\qr"
                  "\\partightenfactor0\n\n\\f0\\fs24 \\cf0 para one\\\n\\pard\\tx560\\tx1120\\sl-400\\slleading60\\pardirnatural\\qj"
                  "\\partightenfactor0\n\\cf0 para two\\\n}");
        read_case("apple-document",
                  "{\\rtf1\\ansi\\ansicpg1252\\cocoartf2869\n\\readonlydoc1\\cocoatextscaling0\\cocoaplatform0{\\fonttbl\\f0"
                  "\\fswiss\\fcharset0 Helvetica;}\n{\\colortbl;\\red255\\green255\\blue255;}\n{\\*\\expandedcolortbl;;}\n{\\info\n"
                  "{\\title T}\n{\\author A}}\\paperw11900\\paperh16840\\margl1440\\margr1440\\vieww10000\\viewh8000\\viewkind1\n"
                  "\\hyphauto1\\hyphfactor50\n\\deftab720\n\\pard\\pardirnatural\\partightenfactor0\n\n\\f0\\fs24 \\cf0 x}");
        read_case("hand-written",
                  "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0\\froman Times;}{\\f1\\fmodern Courier;}}{\\colortbl;\\red0\\green0\\blue255;}"
                  "\\f0\\fs30 Plain {\\b bold {\\i both}} \\cf1 blue\\cf0  \\f1 mono\\f0 \\par {\\*\\unknown skipped}Next "
                  "\\line line\\tab tab \\{\\}\\\\ \\emdash\\endash\\bullet\\lquote\\rquote\\ldblquote\\rdblquote\\~ "
                  "\\u8364?\\uc2\\u8364xx done.}");
        read_case("not rtf", "{\\notrtf}");

        /* plain text and RTFD */
        NSDictionary *pd = nil;
        NSAttributedString *plain = [[NSAttributedString alloc]
                  initWithData:[@"caf\u00e9\nline" dataUsingEncoding:NSUTF8StringEncoding]
                       options:@{NSDocumentTypeDocumentOption : NSPlainTextDocumentType}
            documentAttributes:&pd
                         error:NULL];
        printf("== plain text\n");
        show_runs(plain);
        show_doc(pd);
        NSData *latin = [plain dataFromRange:NSMakeRange(0, plain.length)
                          documentAttributes:@{NSDocumentTypeDocumentAttribute : NSPlainTextDocumentType,
                                               NSCharacterEncodingDocumentAttribute : @(NSISOLatin1StringEncoding)}
                                       error:NULL];
        printf("latin-1 bytes %lu\n", (unsigned long)latin.length);

        NSMutableAttributedString *withAttachment = str(@"before after", helv);
        NSFileWrapper *fw = [[NSFileWrapper alloc] initRegularFileWithContents:[@"hello" dataUsingEncoding:NSUTF8StringEncoding]];
        fw.preferredFilename = @"note.txt";
        NSTextAttachment *att = [[NSTextAttachment alloc] initWithFileWrapper:fw];
        [withAttachment insertAttributedString:[NSAttributedString attributedStringWithAttachment:att] atIndex:7];
        NSFileWrapper *rtfd = [withAttachment RTFDFileWrapperFromRange:NSMakeRange(0, withAttachment.length)
                                                    documentAttributes:@{}];
        printf("== rtfd: %s\n", [[[[rtfd fileWrappers] allKeys] sortedArrayUsingSelector:@selector(compare:)]
                                    componentsJoinedByString:@","]
                                    .UTF8String);
        NSAttributedString *back = [[NSAttributedString alloc] initWithRTFDFileWrapper:rtfd documentAttributes:NULL];
        show_runs(back);
        NSData *flat = [withAttachment RTFDFromRange:NSMakeRange(0, withAttachment.length) documentAttributes:@{}];
        NSAttributedString *flatBack = [[NSAttributedString alloc] initWithRTFD:flat documentAttributes:NULL];
        printf("flat rtfd read back %d attachments %d\n", flatBack != nil, flatBack.containsAttachments);
        printf("textTypes contains rtf %d rtfd %d\n", [[NSAttributedString textTypes] containsObject:@"public.rtf"],
               [[NSAttributedString textTypes] containsObject:@"com.apple.rtfd"]);
    }
    return 0;
}
