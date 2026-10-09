/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-uifoundation-test: UIFoundation (fonts, font descriptors, paragraph
 * styles, shadows, attribute names, string measuring and drawing), as apps
 * reach it through AppKit. Diff the output of runs against Apple's and
 * Finch's frameworks, skipping the first line (which framework loaded):
 *
 *   finch-uifoundation-test [font] [reference]
 *   DYLD_FRAMEWORK_PATH=build/root/System/Library/Frameworks:build/root/System/Library/PrivateFrameworks \
 *     FINCH_FONT_DIRS=build/root/System/Library/Fonts finch-uifoundation-test
 *   finch-uifoundation-test --write reference    (on macOS, against Apple's)
 *   finch-uifoundation-test --dump dir ...        (also write each render and its reference as PPM)
 *
 * Metrics, glyphs and string sizes use a font both systems have (Roboto,
 * from Skia's test fonts) and compare exactly. The system fonts differ (SF
 * on macOS, Inter on Finch), so for them only sizes, weights and descriptor
 * keys are compared. Drawing is compared with reference renders made by
 * Apple's frameworks (uifoundation-reference.bin), within a tolerance, as
 * finch-cg-draw-test does.
 */
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <zlib.h>

static NSFont *roboto;

static void
out(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void
out(NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    printf("%s\n", s.UTF8String);
}

/* Addresses differ from run to run. */
static NSString *
masked(NSString *s)
{
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-f]+" options:0 error:nil];
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@"0x?"];
}

static NSString *
chain(id o)
{
    NSMutableArray *names = [NSMutableArray array];
    for (Class c = object_getClass(o); c; c = class_getSuperclass(c))
        [names addObject:NSStringFromClass(c)];
    return [names componentsJoinedByString:@" : "];
}

static NSString *
r3(CGFloat v)
{
    NSString *s = [NSString stringWithFormat:@"%.3f", v];
    return [s isEqual:@"-0.000"] ? @"0.000" : s;
}

static NSString *
rect3(NSRect r)
{
    return [NSString stringWithFormat:@"{%@ %@ %@ %@}", r3(r.origin.x), r3(r.origin.y), r3(r.size.width), r3(r.size.height)];
}

static NSString *
size3(NSSize s)
{
    return [NSString stringWithFormat:@"{%@ %@}", r3(s.width), r3(s.height)];
}

/* A keyed archive's root object: its keys, with the types and (for numbers and strings) values. */
static NSString *
archived(id o)
{
    NSData *a = [NSKeyedArchiver archivedDataWithRootObject:o requiringSecureCoding:NO error:nil];
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:a options:0 format:nil error:nil];
    NSArray *objects = plist[@"$objects"];
    NSDictionary *root = objects[1];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in [root.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if ([k isEqual:@"$class"]) {
            NSUInteger i = [[root[k] description] rangeOfString:@"value = "].location;
            NSInteger idx = [[[root[k] description] substringFromIndex:i + 8] integerValue];
            [parts addObject:[NSString stringWithFormat:@"class=%@", objects[idx][@"$classname"]]];
            continue;
        }
        id v = root[k];
        if ([v isKindOfClass:[NSNumber class]]) {
            /* Integer, real or boolean (not the integer's width). */
            const char *t = [v objCType];
            const char *kind = strchr("cB", t[0]) ? "b" : strchr("fd", t[0]) ? "r" : "i";
            [parts addObject:[NSString stringWithFormat:@"%@=%@(%s)", k, v, kind]];
        }
        else if ([v isKindOfClass:[NSData class]])
            [parts addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
        else {
            NSString *d = [v description];
            NSUInteger i = [d rangeOfString:@"value = "].location;
            id target = i != NSNotFound ? objects[[[d substringFromIndex:i + 8] integerValue]] : v;
            if ([target isKindOfClass:[NSString class]])
                [parts addObject:[NSString stringWithFormat:@"%@=\"%@\"", k, target]];
            else if ([target isKindOfClass:[NSDictionary class]] && target[@"$class"])
                [parts addObject:[NSString stringWithFormat:@"%@=<object>", k]];
            else
                [parts addObject:[NSString stringWithFormat:@"%@=%@", k, target]];
        }
    }
    return [parts componentsJoinedByString:@" "];
}

static id
roundtrip(id o, Class cls)
{
    NSError *e = nil;
    NSData *a = [NSKeyedArchiver archivedDataWithRootObject:o requiringSecureCoding:YES error:&e];
    if (!a)
        return [NSString stringWithFormat:@"archive error %ld", (long)e.code];
    id b = [NSKeyedUnarchiver unarchivedObjectOfClass:cls fromData:a error:&e];
    return b ? b : [NSString stringWithFormat:@"unarchive error %ld", (long)e.code];
}

#pragma mark - Constants

static void
test_constants(void)
{
    static const char *names[] = {
        "NSAccessibilitySpellingStateAttributeName", "NSAdaptiveImageGlyphAttributeName",
        "NSAllRomanInputSourcesLocaleIdentifier", "NSAntialiasThresholdChangedNotification",
        "NSAppearanceDocumentAttribute", "NSAttachmentAttributeName", "NSAttachmentEditableDataAttributeName",
        "NSAttachmentEditableDataTypeIdentifierAttributeName", "NSAuthorDocumentAttribute",
        "NSBackgroundColorAttributeName", "NSBackgroundColorDocumentAttribute", "NSBackgroundLayoutTrace",
        "NSBaselineOffsetAttributeName", "NSBaseURLDocumentOption", "NSBottomMarginDocumentAttribute",
        "NSCategoryDocumentAttribute", "NSCharacterEncodingDocumentAttribute", "NSCharacterEncodingDocumentOption",
        "NSCharacterShapeAttributeName", "NSCocoaRTFVersionDocumentAttribute", "NSCocoaVersionDocumentAttribute",
        "NSCommentDocumentAttribute", "NSCompanyDocumentAttribute", "NSContainerTrace",
        "NSConvertedDocumentAttribute", "NSCopyrightDocumentAttribute", "NSCreationTimeDocumentAttribute",
        "NSCursorAttributeName", "NSDataDetectionAttributeName", "NSDefaultAttributesDocumentAttribute",
        "NSDefaultAttributesDocumentOption", "NSDefaultFontExcludedDocumentAttribute",
        "NSDefaultTabIntervalDocumentAttribute", "NSDisplayNameDocumentAttribute", "NSDocFormatTextDocumentType",
        "NSDocumentTypeDocumentAttribute", "NSDocumentTypeDocumentOption", "NSDominantLanguageAttributeName",
        "NSDominantScriptAttributeName", "NSEditorDocumentAttribute", "NSEmojiImageContentTypeDefault",
        "NSExcludedElementsDocumentAttribute", "NSExpansionAttributeName", "NSFileTypeDocumentAttribute",
        "NSFileTypeDocumentOption", "NSFirstLineHeadIndentRulerMarkerTag", "NSFontAttributeName",
        "NSFontCascadeListAttribute", "NSFontCharacterSetAttribute", "NSFontDescriptorSystemDesignDefault",
        "NSFontDescriptorSystemDesignMonospaced", "NSFontDescriptorSystemDesignRounded",
        "NSFontDescriptorSystemDesignSerif", "NSFontDesignDefault", "NSFontDesignTrait", "NSFontFaceAttribute",
        "NSFontFamilyAttribute", "NSFontFeatureSelectorIdentifierKey", "NSFontFeatureSettingsAttribute",
        "NSFontFeatureTypeIdentifierKey", "NSFontFixedAdvanceAttribute", "NSFontKernAttribute",
        "NSFontMatrixAttribute", "NSFontNameAttribute", "NSFontSetChangedNotification", "NSFontSizeAttribute",
        "NSFontSlantTrait", "NSFontSymbolicTrait", "NSFontSystemDesignDefault", "NSFontSystemDesignRounded",
        "NSFontSystemDesignTrait", "NSFontTextStyleBody", "NSFontTextStyleCallout", "NSFontTextStyleCaption1",
        "NSFontTextStyleCaption2", "NSFontTextStyleFootnote", "NSFontTextStyleHeadline", "NSFontTextStyleLargeTitle",
        "NSFontTextStyleSubheadline", "NSFontTextStyleTitle1", "NSFontTextStyleTitle2", "NSFontTextStyleTitle3",
        "NSFontTraitAttributeName", "NSFontTraitsAttribute", "NSFontVariationAttribute",
        "NSFontVariationAxisDefaultValueKey", "NSFontVariationAxisIdentifierKey",
        "NSFontVariationAxisMaximumValueKey", "NSFontVariationAxisMinimumValueKey", "NSFontVariationAxisNameKey",
        "NSFontVisibleNameAttribute", "#NSFontWeightBlack", "#NSFontWeightBold", "#NSFontWeightHeavy",
        "#NSFontWeightLight", "#NSFontWeightMedium", "#NSFontWeightRegular", "#NSFontWeightSemibold",
        "#NSFontWeightThin", "NSFontWeightTrait", "#NSFontWeightUltraLight", "#NSFontWidthCompressed",
        "#NSFontWidthCondensed", "#NSFontWidthExpanded", "#NSFontWidthStandard", "NSFontWidthTrait",
        "NSForegroundColorAttributeName", "NSGeneratorDocumentAttribute", "NSGlyphDisplayInvalidationTrace",
        "NSGlyphGenerationTrace", "NSGlyphGeometryTrace", "NSGlyphInfoAttributeName",
        "NSGrammarLeftOffsetAttributeName", "NSGrammarRightOffsetAttributeName", "NSHeadIndentRulerMarkerTag",
        "NSHTMLAllowNetworkAccess", "NSHTMLTextDocumentType", "NSHyphenationFactorDocumentAttribute",
        "NSIgnoringSubstitutionAttributeName", "NSKernAttributeName", "NSKeywordsDocumentAttribute",
        "NSLanguageAttributeName", "NSLeftMarginDocumentAttribute", "NSLigatureAttributeName", "NSLinkAttributeName",
        "NSMacSimpleTextDocumentType", "NSManagerDocumentAttribute", "NSMarkedClauseSegmentAttributeName",
        "NSMarkedTextSelectionAttributeName", "NSMarkedTextStyleAttributeName",
        "NSModificationTimeDocumentAttribute", "NSNoIndexDocumentAttribute", "NSObliquenessAttributeName",
        "NSOfficeOpenXMLTextDocumentType", "NSOpenDocumentTextDocumentType", "NSOriginalFontAttributeName",
        "NSOrthographyAttributeName", "NSPaperMarginDocumentAttribute", "NSPaperSizeDocumentAttribute",
        "NSParagraphAttachmentAttributeName", "NSParagraphStyleAttributeName", "NSPlainTextDocumentType",
        "NSPOSIXLocaleIdentifier", "NSPrefixSpacesDocumentAttribute", "NSReaderDelegateDocumentOption",
        "NSReadOnlyDocumentAttribute", "NSReplacedStringAttributeName", "NSRightMarginDocumentAttribute",
        "NSRTFDTextDocumentType", "NSRTFException", "NSRTFTextDocumentType", "NSShadowAttributeName",
        "NSSmallCapsAttributeName", "NSSourceTextScalingDocumentAttribute", "NSSourceTextScalingDocumentOption",
        "NSSourceTextScalingDocumentReadingOption", "NSSpellingStateAttributeName", "NSStrikeThroughAttributeName",
        "NSStrikethroughColorAttributeName", "NSStrikethroughStyleAttributeName", "NSStrokeColorAttributeName",
        "NSStrokeWidthAttributeName", "NSSubjectDocumentAttribute", "NSSuperscriptAttributeName",
        "NSTabColumnTerminatorsAttributeName", "NSTailIndentRulerMarkerTag", "NSTargetTextScalingDocumentOption",
        "NSTargetTextScalingDocumentReadingOption", "NSTemporaryTextCorrectionAttributeName",
        "NSTextAlternativesAttributeName", "NSTextAlternativesDisplayStyleAttributeName",
        "NSTextAlternativesSelectedAlternativeKey", "NSTextAlternativesSelectedAlternativeStringNotification",
        "NSTextAnimationAttributeName", "NSTextCheckedAttributeName",
        "NSTextContentManagerUnsupportedAttributeNotification",
        "NSTextContentStorageUnsupportedAttributeAddedNotification", "NSTextCorrectionAttributeName",
        "NSTextDrawingTrace", "NSTextEditedAttributeName", "NSTextEffectAttributeName",
        "NSTextEffectLetterpressStyle", "NSTextEncodingNameDocumentAttribute", "NSTextEncodingNameDocumentOption",
        "NSTextHighlightAttributeName", "NSTextHighlightColorSchemeAttributeName", "NSTextHighlightColorSchemeBlue",
        "NSTextHighlightColorSchemeDefault", "NSTextHighlightColorSchemeMint", "NSTextHighlightColorSchemeOrange",
        "NSTextHighlightColorSchemePink", "NSTextHighlightColorSchemePurple",
        "NSTextHighlightOutlineColorAttributeName", "NSTextHighlightStyleAttributeName",
        "NSTextHighlightStyleDefault", "NSTextHighlightStyleOutlined", "NSTextHighlightStyleSystemDefault",
        "NSTextKeyTrace", "NSTextKit1ListMarkerFormatDocumentOption", "NSTextLayoutSectionOrientation",
        "NSTextLayoutSectionRange", "NSTextLayoutSectionsAttribute", "NSTextListMarkerAttachment",
        "NSTextListMarkerBox", "NSTextListMarkerCheck", "NSTextListMarkerCircle", "NSTextListMarkerDecimal",
        "NSTextListMarkerDiamond", "NSTextListMarkerDisc", "NSTextListMarkerHyphen",
        "NSTextListMarkerLowercaseAlpha", "NSTextListMarkerLowercaseHexadecimal", "NSTextListMarkerLowercaseLatin",
        "NSTextListMarkerLowercaseRoman", "NSTextListMarkerOctal", "NSTextListMarkerSquare",
        "NSTextListMarkerUppercaseAlpha", "NSTextListMarkerUppercaseHexadecimal", "NSTextListMarkerUppercaseLatin",
        "NSTextListMarkerUppercaseRoman", "NSTextLocationTypeCountable", "NSTextMouseTrace",
        "NSTextParagraphAnchoredAttachmentAttributeName", "NSTextRevertedAttributeName", "NSTextScaleAttributeName",
        "NSTextScaleSecondary", "NSTextScalingDocumentAttribute", "NSTextScalingOverrideDocumentReadingOption",
        "NSTextSizeMultiplierDocumentOption", "NSTextStorageDidProcessEditingNotification",
        "NSTextStorageWillProcessEditingNotification", "NSTextViewDidChangeSelectionNotification",
        "NSTextViewDidChangeTypingAttributesNotification", "NSTextViewWillChangeNotifyingTextViewNotification",
        "NSTimeoutDocumentOption", "NSTitleDocumentAttribute", "NSToolTipAttributeName",
        "NSTopMarginDocumentAttribute", "NSTrackingAttributeName", "NSTypesettingTrace",
        "NSTypographyFeatureAttributeName", "NSUnderlineColorAttributeName", "NSUnderlineStyleAttributeName",
        "NSUTIDocumentAttribute", "NSVerticalGlyphFormAttributeName", "NSViewModeDocumentAttribute",
        "NSViewSizeDocumentAttribute", "NSViewZoomDocumentAttribute", "NSWebArchiveTextDocumentType",
        "NSWebPreferencesDocumentOption", "NSWebResourceLoadDelegateDocumentOption", "NSWordMLTextDocumentType",
        "NSWritingDirectionAttributeName", "NSWritingToolsExclusionAttributeName", "NSZipTextDocumentType",
        "UIFontDescriptorCascadeListAttribute", "UIFontDescriptorCharacterSetAttribute",
        "UIFontDescriptorFaceAttribute", "UIFontDescriptorFamilyAttribute",
        "UIFontDescriptorFeatureSettingsAttribute", "UIFontDescriptorFixedAdvanceAttribute",
        "UIFontDescriptorMatrixAttribute", "UIFontDescriptorNameAttribute", "UIFontDescriptorOpticalSizeAttribute",
        "UIFontDescriptorPostScriptNameAttribute", "UIFontDescriptorSizeAttribute",
        "UIFontDescriptorSystemDesignDefault", "UIFontDescriptorSystemDesignMonospaced",
        "UIFontDescriptorSystemDesignRounded", "UIFontDescriptorSystemDesignSerif",
        "UIFontDescriptorTextStyleAttribute", "UIFontDescriptorTraitsAttribute",
        "UIFontDescriptorVariationAttribute", "UIFontDescriptorVisibleNameAttribute", "UIFontDesignDefault",
        "UIFontDesignTrait", "UIFontFeatureSelectorIdentifierKey", "UIFontFeatureTypeIdentifierKey",
        "UIFontSlantTrait", "UIFontSymbolicTrait", "UIFontSystemFontDesignAlternate",
        "UIFontSystemFontDesignCompact", "UIFontSystemFontDesignCondensed", "UIFontSystemFontDesignDefault",
        "UIFontSystemFontDesignMonospaced", "UIFontSystemFontDesignRounded", "UIFontSystemFontDesignSerif",
        "UIFontSystemFontDesignTrait", "UIFontSystemFontGradeTrait", "#UIFontWeightBlack", "#UIFontWeightBold",
        "#UIFontWeightHeavy", "#UIFontWeightLight", "#UIFontWeightMedium", "#UIFontWeightRegular",
        "#UIFontWeightSemibold", "#UIFontWeightThin", "UIFontWeightTrait", "#UIFontWeightUltraLight",
        "#UIFontWidthCompressed", "#UIFontWidthCondensed", "#UIFontWidthExpanded", "#UIFontWidthStandard",
        "UIFontWidthTrait", "UIInlinedValueMarker",
    };
    out(@"[constants]");
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        const char *n = names[i];
        BOOL number = n[0] == '#';
        if (number)
            n++;
        void *p = dlsym(RTLD_DEFAULT, n);
        if (!p)
            out(@"%s MISSING", n);
        else if (number)
            out(@"%s = %.9g", n, *(double *)p);
        else
            out(@"%s = %@", n, *(__unsafe_unretained NSString **)p);
    }
}

#pragma mark - Fonts

static void
test_font_classes(void)
{
    out(@"[font classes]");
    CTFontRef ct = CTFontCreateWithName(CFSTR("Helvetica"), 12, NULL);
    out(@"CTFont: %@", chain((__bridge id)ct));
    out(@"CTFont is NSFont: %d", [(__bridge id)ct isKindOfClass:[NSFont class]]);
    out(@"CTFont pointSize: %g", [(__bridge NSFont *)ct pointSize]);
    CFRelease(ct);
    NSFont *f = [NSFont fontWithName:@"Helvetica" size:12];
    out(@"NSFont: %@", chain(f));
    out(@"type ID is CTFont's: %d", CFGetTypeID((__bridge CFTypeRef)f) == CTFontGetTypeID());
    out(@"CTFontGetSize: %g", CTFontGetSize((__bridge CTFontRef)f));
    out(@"system: %@", chain([NSFont systemFontOfSize:13]));
    NSFontDescriptor *d = f.fontDescriptor;
    out(@"descriptor: %@", chain(d));
    out(@"descriptor type ID is CTFontDescriptor's: %d", CFGetTypeID((__bridge CFTypeRef)d) == CTFontDescriptorGetTypeID());
    CTFontDescriptorRef cd = CTFontDescriptorCreateWithNameAndSize(CFSTR("Helvetica"), 10);
    out(@"CTFontDescriptor: %@ size %g", chain((__bridge id)cd), [(__bridge NSFontDescriptor *)cd pointSize]);
    CFRelease(cd);
    out(@"NSFont alloc: %d", [NSFont alloc] != nil);
    out(@"fontWithName nil for unknown: %d %d", [NSFont fontWithName:@"NoSuchFont-Finch" size:12] == nil,
        [NSFont fontWithName:@"" size:12] == nil);
    out(@"Helvetica found: %d %d", [NSFont fontWithName:@"Helvetica" size:12] != nil,
        [NSFont fontWithName:@"Helvetica-Bold" size:12] != nil);
    out(@"cached: %d %d", [NSFont fontWithName:@"Helvetica" size:12] == f,
        [NSFont systemFontOfSize:13] == [NSFont systemFontOfSize:13]);
    out(@"supportsSecureCoding: %d %d", [NSFont supportsSecureCoding], [NSFontDescriptor supportsSecureCoding]);
}

/* What a UI font reports that is the same on both systems. */
static NSString *
ui_font(NSFont *f)
{
    NSDictionary *a = f.fontDescriptor.fontAttributes;
    NSMutableArray *keys = [[a.allKeys sortedArrayUsingSelector:@selector(compare:)] mutableCopy];
    NSString *usage = a[@"NSCTFontUIUsageAttribute"];
    return [NSString stringWithFormat:@"size %g fixed %d keys %@ usage %@", f.pointSize, f.isFixedPitch,
                                      [keys componentsJoinedByString:@","], usage ? usage : @"-"];
}

static void
test_ui_fonts(void)
{
    out(@"[UI fonts]");
    out(@"systemFontSize %g small %g label %g", [NSFont systemFontSize], [NSFont smallSystemFontSize], [NSFont labelFontSize]);
    out(@"control sizes: mini %g small %g regular %g large %g", [NSFont systemFontSizeForControlSize:NSControlSizeMini],
        [NSFont systemFontSizeForControlSize:NSControlSizeSmall], [NSFont systemFontSizeForControlSize:NSControlSizeRegular],
        [NSFont systemFontSizeForControlSize:NSControlSizeLarge]);
    out(@"bold: system %d bold %d titleBar %d", (CTFontGetSymbolicTraits((__bridge CTFontRef)[NSFont systemFontOfSize:0]) & kCTFontBoldTrait) != 0,
        (CTFontGetSymbolicTraits((__bridge CTFontRef)[NSFont boldSystemFontOfSize:0]) & kCTFontBoldTrait) != 0,
        (CTFontGetSymbolicTraits((__bridge CTFontRef)[NSFont titleBarFontOfSize:0]) & kCTFontBoldTrait) != 0);
    out(@"system 0: %@", ui_font([NSFont systemFontOfSize:0]));
    out(@"system 20: %@", ui_font([NSFont systemFontOfSize:20]));
    out(@"system -3: %@", ui_font([NSFont systemFontOfSize:-3]));
    out(@"bold 0: %@", ui_font([NSFont boldSystemFontOfSize:0]));
    out(@"label 0: %@", ui_font([NSFont labelFontOfSize:0]));
    out(@"menu 0: %@", ui_font([NSFont menuFontOfSize:0]));
    out(@"menuBar 0: %@", ui_font([NSFont menuBarFontOfSize:0]));
    out(@"message 0: %@", ui_font([NSFont messageFontOfSize:0]));
    out(@"palette 0: %@", ui_font([NSFont paletteFontOfSize:0]));
    out(@"toolTips 0: %@", ui_font([NSFont toolTipsFontOfSize:0]));
    out(@"controlContent 0: %@", ui_font([NSFont controlContentFontOfSize:0]));
    out(@"titleBar 0: %@", ui_font([NSFont titleBarFontOfSize:0]));
    out(@"user 0: size %g", [NSFont userFontOfSize:0].pointSize);
    out(@"user -1: size %g", [NSFont userFontOfSize:-1].pointSize);
    out(@"userFixedPitch 0: size %g fixed %d", [NSFont userFixedPitchFontOfSize:0].pointSize,
        [NSFont userFixedPitchFontOfSize:0].isFixedPitch);
    const NSFontWeight weights[] = {NSFontWeightUltraLight, NSFontWeightThin, NSFontWeightLight, NSFontWeightRegular,
                                    NSFontWeightMedium, NSFontWeightSemibold, NSFontWeightBold, NSFontWeightHeavy,
                                    NSFontWeightBlack, 0.1, 0.35, 0.9};
    for (size_t i = 0; i < sizeof weights / sizeof weights[0]; i++) {
        out(@"weight %g: %@", weights[i], ui_font([NSFont systemFontOfSize:12 weight:weights[i]]));
        NSFont *m = [NSFont monospacedSystemFontOfSize:12 weight:weights[i]];
        out(@"  monospaced: size %g fixed %d", m.pointSize, m.isFixedPitch);
        out(@"  monospaced digits: %@", ui_font([NSFont monospacedDigitSystemFontOfSize:12 weight:weights[i]]));
    }
    NSFont *w = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular width:NSFontWidthCondensed];
    out(@"width condensed: %@ %@", ui_font(w), w.fontDescriptor.fontAttributes[NSFontTraitsAttribute]);
    NSFont *s = [NSFont systemFontOfSize:13];
    out(@"system fontWithSize 20: %@", ui_font([s fontWithSize:20]));
    out(@"bold fontWithSize 9: %@", ui_font([[NSFont boldSystemFontOfSize:13] fontWithSize:9]));
    out(@"system descriptor bold: %@",
        ui_font([NSFont fontWithDescriptor:[s.fontDescriptor fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitBold]
                                      size:0]));
    out(@"system from descriptor: %@", ui_font([NSFont fontWithDescriptor:s.fontDescriptor size:0]));
    NSFontDescriptor *serif = [s.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignSerif];
    out(@"design serif: %@", serif.fontAttributes[NSFontTraitsAttribute][@"NSCTFontUIFontDesignTrait"]);
    out(@"design on Helvetica: %@",
        [[NSFont fontWithName:@"Helvetica" size:12].fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded]);
    NSFontTextStyle styles[] = {NSFontTextStyleLargeTitle, NSFontTextStyleTitle1, NSFontTextStyleTitle2, NSFontTextStyleTitle3,
                                NSFontTextStyleHeadline, NSFontTextStyleSubheadline, NSFontTextStyleBody,
                                NSFontTextStyleCallout, NSFontTextStyleFootnote, NSFontTextStyleCaption1,
                                NSFontTextStyleCaption2};
    for (size_t i = 0; i < sizeof styles / sizeof styles[0]; i++) {
        NSFontDescriptor *d = [NSFontDescriptor preferredFontDescriptorForTextStyle:styles[i] options:@{}];
        out(@"style %@: size %g usage %@", styles[i], d.pointSize, d.fontAttributes[@"NSCTFontUIUsageAttribute"]);
    }
    out(@"archive system: %@", archived([NSFont systemFontOfSize:13]));
    out(@"archive bold system: %@", archived([NSFont boldSystemFontOfSize:12]));
    out(@"roundtrip system: %d", roundtrip(s, [NSFont class]) == s);
    out(@"roundtrip bold: %d", roundtrip([NSFont boldSystemFontOfSize:12], [NSFont class]) == [NSFont boldSystemFontOfSize:12]);
}

static void
test_roboto(void)
{
    out(@"[Roboto]");
    if (!roboto) {
        out(@"no Roboto");
        return;
    }
    NSFont *f = roboto;
    CTFontRef c = (__bridge CTFontRef)f;
    out(@"names: %@ | %@ | %@", f.fontName, f.familyName, f.displayName);
    out(@"description: %@", masked(f.description));
    out(@"descriptor: %@", masked(f.fontDescriptor.description));
    out(@"pointSize %g", f.pointSize);
    out(@"ascender %@ descender %@ leading %@ capHeight %@ xHeight %@", r3(f.ascender), r3(f.descender), r3(f.leading),
        r3(f.capHeight), r3(f.xHeight));
    out(@"underline %@ %@ italicAngle %@", r3(f.underlinePosition), r3(f.underlineThickness), r3(f.italicAngle));
    out(@"boundingRectForFont %@", rect3(f.boundingRectForFont));
    out(@"maximumAdvancement %@", size3(f.maximumAdvancement));
    const CGFloat *m = f.matrix;
    out(@"matrix %g %g %g %g %g %g", m[0], m[1], m[2], m[3], m[4], m[5]);
    NSAffineTransformStruct t = f.textTransform.transformStruct;
    out(@"textTransform %g %g %g %g %g %g", t.m11, t.m12, t.m21, t.m22, t.tX, t.tY);
    out(@"numberOfGlyphs %lu fixedPitch %d encoding %lu", (unsigned long)f.numberOfGlyphs, f.isFixedPitch,
        (unsigned long)f.mostCompatibleStringEncoding);
    out(@"covered: A %d é %d 中 %d", [f.coveredCharacterSet characterIsMember:'A'],
        [f.coveredCharacterSet characterIsMember:0xE9], [f.coveredCharacterSet characterIsMember:0x4E2D]);
    UniChar chars[] = {'H', 'e', 'l', 'l', 'o', ' ', 'W', 'g'};
    CGGlyph glyphs[8];
    CTFontGetGlyphsForCharacters(c, chars, glyphs, 8);
    NSRect rects[8];
    NSSize advances[8];
    [f getBoundingRects:rects forCGGlyphs:glyphs count:8];
    [f getAdvancements:advances forCGGlyphs:glyphs count:8];
    for (int i = 0; i < 8; i++)
        out(@"glyph '%C' %u: rect %@ (%@) advance %@ (%@)", chars[i], glyphs[i], rect3(rects[i]),
            rect3([f boundingRectForCGGlyph:glyphs[i]]), size3(advances[i]), size3([f advancementForCGGlyph:glyphs[i]]));
    out(@"glyphWithName .notdef %u", [f glyphWithName:@".notdef"]);
    out(@"renderingMode %lu printerFont self %d", (unsigned long)f.renderingMode, f.printerFont == f);
    NSFont *f10 = [f fontWithSize:10];
    out(@"fontWithSize 10: %@ %g", f10.fontName, f10.pointSize);
    out(@"size 0: %g, size -5: %g", [NSFont fontWithName:@"Roboto-Regular" size:0].pointSize,
        [NSFont fontWithName:@"Roboto-Regular" size:-5].pointSize);
    out(@"family name works: %@", [NSFont fontWithName:@"Roboto" size:12].fontName);
    NSFont *same = [NSFont fontWithName:@"Roboto-Regular" size:24];
    out(@"isEqual %d hash %d copy %d", [f isEqual:same], f.hash == same.hash, [f copy] == f);
    out(@"isEqual other size %d", [f isEqual:f10]);
    out(@"archive: %@", archived(f));
    id back = roundtrip(f, [NSFont class]);
    out(@"roundtrip: %@ equal %d", [back fontName], [back isEqual:f]);
    CGFloat mm[6] = {24, 0, 4, 24, 0, 0};
    NSFont *sl = [NSFont fontWithName:@"Roboto-Regular" matrix:mm];
    const CGFloat *sm = sl.matrix;
    out(@"matrix font: size %g matrix %g %g %g %g %g %g", sl.pointSize, sm[0], sm[1], sm[2], sm[3], sm[4], sm[5]);
    out(@"matrix font description: %@", masked(sl.description));
    out(@"matrix font archive: %@", archived(sl));
    id slb = roundtrip(sl, [NSFont class]);
    out(@"matrix font roundtrip: %d", [slb isEqual:sl]);
    out(@"identity matrix is NULL: %d", NSFontIdentityMatrix == NULL);
    out(@"fontWithName:matrix: identity: %g", [NSFont fontWithName:@"Roboto-Regular" matrix:NSFontIdentityMatrix].pointSize);
}

static void
test_descriptors(void)
{
    out(@"[font descriptors]");
    if (!roboto)
        return;
    NSFontDescriptor *d = roboto.fontDescriptor;
    out(@"attributes: %@", d.fontAttributes);
    out(@"postscriptName %@ pointSize %g matrix %@ traits %u", d.postscriptName, d.pointSize, d.matrix, d.symbolicTraits);
    out(@"objectForKey family: %@", [d objectForKey:NSFontFamilyAttribute]);
    out(@"withSize: %@", [d fontDescriptorWithSize:9].fontAttributes);
    out(@"withFace: %@", [d fontDescriptorWithFace:@"Bold"].fontAttributes);
    out(@"withFamily: %@", [d fontDescriptorWithFamily:@"Helvetica"].fontAttributes);
    out(@"adding: %@", [d fontDescriptorByAddingAttributes:@{NSFontVisibleNameAttribute : @"Robo"}].fontAttributes);
    NSFontDescriptor *dm = [d fontDescriptorWithMatrix:[NSAffineTransform transform]];
    out(@"withMatrix keys: %@", [dm.fontAttributes.allKeys sortedArrayUsingSelector:@selector(compare:)]);
    out(@"withMatrix matrix: %@", dm.matrix ? @"yes" : @"no");
    out(@"bold Roboto: %@", [d fontDescriptorWithSymbolicTraits:NSFontDescriptorTraitBold]);
    NSFontDescriptor *fam = [NSFontDescriptor fontDescriptorWithFontAttributes:@{NSFontFamilyAttribute : @"Roboto"}];
    out(@"matching: %@", masked([fam matchingFontDescriptorsWithMandatoryKeys:nil].description));
    out(@"matching one: %@", [fam matchingFontDescriptorWithMandatoryKeys:nil].fontAttributes);
    out(@"matching nonexistent: %@",
        [[NSFontDescriptor fontDescriptorWithFontAttributes:@{NSFontFamilyAttribute : @"NoSuchFamilyFinch"}]
            matchingFontDescriptorWithMandatoryKeys:nil]);
    out(@"withName size 0: %@", [NSFontDescriptor fontDescriptorWithName:@"Roboto-Regular" size:0].fontAttributes);
    out(@"withName matrix keys: %@",
        [[NSFontDescriptor fontDescriptorWithName:@"Roboto-Regular" matrix:[NSAffineTransform transform]]
                .fontAttributes.allKeys sortedArrayUsingSelector:@selector(compare:)]);
    out(@"empty: %@ | %@", masked([NSFontDescriptor new].description),
        masked([[NSFontDescriptor alloc] initWithFontAttributes:nil].description));
    NSFontDescriptor *same = [NSFontDescriptor fontDescriptorWithName:@"Roboto-Regular" size:24];
    out(@"isEqual %d hash %d copy class %s", [d isEqual:same], d.hash == same.hash, object_getClassName([d copy]));
    NSFont *fd = [NSFont fontWithDescriptor:fam size:11];
    out(@"font from family descriptor: %@ %g", fd.fontName, fd.pointSize);
    out(@"font from descriptor size 0: %g", [NSFont fontWithDescriptor:d size:0].pointSize);
    out(@"archive: %@", archived(d));
    NSFontDescriptor *back = roundtrip(d, [NSFontDescriptor class]);
    out(@"roundtrip: %d %s", [back isEqual:d], object_getClassName(back));
    out(@"requiresFontAssetRequest %d", d.requiresFontAssetRequest);
}

#pragma mark - Paragraph styles, shadows, tabs, lists

static void
test_paragraph_styles(void)
{
    out(@"[paragraph styles]");
    NSParagraphStyle *d = [NSParagraphStyle defaultParagraphStyle];
    out(@"default: %@", chain(d));
    out(@"%@", d.description);
    out(@"default same: %d", d == [NSParagraphStyle defaultParagraphStyle]);
    out(@"copy same %d mutableCopy %@ equal %d hash equal %d", [d copy] == d, chain([d mutableCopy]),
        [d isEqual:[d mutableCopy]], d.hash == [[d mutableCopy] hash]);
    out(@"alignment %ld lineBreakMode %ld direction %ld tighten %d lineBreakStrategy %lu", (long)d.alignment,
        (long)d.lineBreakMode, (long)d.baseWritingDirection, d.allowsDefaultTighteningForTruncation,
        (unsigned long)d.lineBreakStrategy);
    out(@"tabs %lu first %@ textBlocks %@ textLists %@", (unsigned long)d.tabStops.count, d.tabStops.firstObject,
        d.textBlocks, d.textLists);
    out(@"writing direction: ar %ld he %ld en %ld nil %ld", (long)[NSParagraphStyle defaultWritingDirectionForLanguage:@"ar"],
        (long)[NSParagraphStyle defaultWritingDirectionForLanguage:@"he"],
        (long)[NSParagraphStyle defaultWritingDirectionForLanguage:@"en"],
        (long)[NSParagraphStyle defaultWritingDirectionForLanguage:nil]);
    out(@"archive default: %@", archived(d));

    NSMutableParagraphStyle *m = [d mutableCopy];
    m.alignment = NSTextAlignmentCenter;
    m.lineSpacing = 3.5;
    m.paragraphSpacing = 8;
    m.paragraphSpacingBefore = 2;
    m.headIndent = 5;
    m.firstLineHeadIndent = 6;
    m.tailIndent = -7;
    m.minimumLineHeight = 10;
    m.maximumLineHeight = 20;
    m.lineHeightMultiple = 1.5;
    m.lineBreakMode = NSLineBreakByTruncatingTail;
    m.baseWritingDirection = NSWritingDirectionRightToLeft;
    m.hyphenationFactor = 0.5;
    m.defaultTabInterval = 36;
    m.allowsDefaultTighteningForTruncation = NO;
    m.headerLevel = 2;
    m.lineBreakStrategy = NSLineBreakStrategyPushOut;
    m.usesDefaultHyphenation = YES;
    out(@"%@", m.description);
    out(@"archive mutable: %@", archived(m));
    NSParagraphStyle *mc = [m copy];
    out(@"copy: %@ equal %d hash equal %d", chain(mc), [mc isEqual:m], mc.hash == m.hash);
    out(@"not equal to default: %d", [m isEqual:d]);
    NSParagraphStyle *back = roundtrip(m, [NSParagraphStyle class]);
    out(@"roundtrip: %@ equal %d", chain(back), [back isEqual:m]);
    NSMutableParagraphStyle *t = [NSMutableParagraphStyle new];
    t.tabStops = @[];
    [t addTabStop:[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:50 options:@{}]];
    [t addTabStop:[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:20 options:@{}]];
    out(@"tabs after add: %@", [t.tabStops componentsJoinedByString:@" "]);
    [t removeTabStop:[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:20 options:@{}]];
    out(@"tabs after remove: %@", [t.tabStops componentsJoinedByString:@" "]);
    t.alignment = NSTextAlignmentJustified;
    [t setParagraphStyle:d];
    out(@"after setParagraphStyle: alignment %ld tabs %lu", (long)t.alignment, (unsigned long)t.tabStops.count);
    out(@"[NSParagraphStyle new]: %d", [[NSParagraphStyle new] isEqual:d]);
}

static void
test_tabs_and_lists(void)
{
    out(@"[tabs and lists]");
    for (NSInteger a = 0; a < 5; a++) {
        NSTextTab *t = [[NSTextTab alloc] initWithTextAlignment:a location:10 options:@{}];
        out(@"alignment %ld: %@ type %ld location %g", (long)a, t, (long)t.tabStopType, t.location);
    }
    NSTextTab *t = [[NSTextTab alloc] initWithType:NSRightTabStopType location:12.5];
    out(@"type right: %@ alignment %ld", t, (long)t.alignment);
    t = [[NSTextTab alloc] initWithType:NSCenterTabStopType location:12.5];
    out(@"type center: %@ alignment %ld", t, (long)t.alignment);
    t = [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:40 options:@{}];
    out(@"archive tab: %@", archived(t));
    NSTextTab *u = [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:40 options:@{}];
    out(@"tab equal %d hash %d other %d", [t isEqual:u], t.hash == u.hash,
        [t isEqual:[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:40 options:@{}]]);
    out(@"tab roundtrip: %@", roundtrip(t, [NSTextTab class]));
    NSString *formats[] = {NSTextListMarkerDecimal, NSTextListMarkerLowercaseRoman, NSTextListMarkerUppercaseRoman,
                           NSTextListMarkerLowercaseAlpha, NSTextListMarkerUppercaseAlpha, NSTextListMarkerLowercaseLatin,
                           NSTextListMarkerUppercaseLatin, NSTextListMarkerOctal, NSTextListMarkerLowercaseHexadecimal,
                           NSTextListMarkerUppercaseHexadecimal, NSTextListMarkerDisc, NSTextListMarkerCircle,
                           NSTextListMarkerSquare, NSTextListMarkerHyphen, NSTextListMarkerDiamond,
                           NSTextListMarkerBox, NSTextListMarkerCheck, @"({decimal})", @"plain"};
    for (size_t i = 0; i < sizeof formats / sizeof formats[0]; i++) {
        NSTextList *l = [[NSTextList alloc] initWithMarkerFormat:formats[i] options:0];
        out(@"list %@: 1[%@] 4[%@] 27[%@] 1999[%@]", formats[i], [l markerForItemNumber:1], [l markerForItemNumber:4],
            [l markerForItemNumber:27], [l markerForItemNumber:1999]);
    }
    NSTextList *l = [[NSTextList alloc] initWithMarkerFormat:NSTextListMarkerDecimal options:NSTextListPrependEnclosingMarker];
    l.startingItemNumber = 3;
    out(@"list: %@ options %lu start %ld ordered %d", masked(l.description), (unsigned long)l.listOptions,
        (long)l.startingItemNumber, l.isOrdered);
    out(@"disc ordered %d", [[NSTextList alloc] initWithMarkerFormat:NSTextListMarkerDisc options:0].isOrdered);
    out(@"archive list: %@", archived(l));
}

static void
test_shadows(void)
{
    out(@"[shadows]");
    NSShadow *s = [NSShadow new];
    out(@"default: %@ offset %@ blur %g color nil %d", s, NSStringFromSize(s.shadowOffset), s.shadowBlurRadius,
        s.shadowColor == nil);
    s.shadowOffset = NSMakeSize(2, -3);
    s.shadowBlurRadius = 4;
    out(@"set: %@", s);
    out(@"archive: %@", archived(s));
    NSShadow *t = [s copy];
    out(@"copy: %@ equal %d hash %d", t, [t isEqual:s], t.hash == s.hash);
    t.shadowBlurRadius = 5;
    out(@"changed equal %d", [t isEqual:s]);
    NSShadow *back = roundtrip(s, [NSShadow class]);
    out(@"roundtrip: %@ equal %d", back, [back isEqual:s]);
    s.shadowBlurRadius = -2;
    out(@"negative blur: %g", s.shadowBlurRadius);
}

static void
test_misc(void)
{
    out(@"[misc]");
    NSStringDrawingContext *c = [NSStringDrawingContext new];
    out(@"drawing context: min %g actual %g bounds %@", c.minimumScaleFactor, c.actualScaleFactor,
        NSStringFromRect(c.totalBounds));
    c.minimumScaleFactor = 0.5;
    out(@"min after set %g", c.minimumScaleFactor);
    NSTextAttachment *a = [[NSTextAttachment alloc] initWithData:nil ofType:nil];
    out(@"attachment: bounds %@ contents %@ fileType %@", NSStringFromRect(a.bounds), a.contents, a.fileType);
    a.bounds = NSMakeRect(0, -2, 10, 12);
    out(@"attachment bounds %@", NSStringFromRect(a.bounds));
    NSAttributedString *as = [NSAttributedString attributedStringWithAttachment:a];
    out(@"attachment string: length %lu char %04x attachment same %d", (unsigned long)as.length, [as.string characterAtIndex:0],
        [as attribute:NSAttachmentAttributeName atIndex:0 effectiveRange:NULL] == a);
    out(@"attachment character %04x", NSAttachmentCharacter);
    /* UIFoundation's (unpublished on macOS) conversions between NSTextAlignment and CTTextAlignment. */
    uint8_t (*to_ct)(NSTextAlignment) = dlsym(RTLD_DEFAULT, "NSTextAlignmentToCTTextAlignment");
    NSTextAlignment (*from_ct)(uint8_t) = dlsym(RTLD_DEFAULT, "NSTextAlignmentFromCTTextAlignment");
    if (to_ct && from_ct)
        for (NSTextAlignment a = 0; a < 5; a++)
            out(@"alignment %ld -> CT %u -> %ld", (long)a, to_ct(a), (long)from_ct(to_ct(a)));
}

#pragma mark - The text system

@interface EditLog : NSObject <NSTextStorageDelegate, NSLayoutManagerDelegate>
@end
@implementation EditLog
- (void)textStorage:(NSTextStorage *)ts willProcessEditing:(NSTextStorageEditActions)m range:(NSRange)r changeInLength:(NSInteger)d
{
    out(@"  will process: mask %lu range %@ change %ld", (unsigned long)m, NSStringFromRange(r), (long)d);
}
- (void)textStorage:(NSTextStorage *)ts didProcessEditing:(NSTextStorageEditActions)m range:(NSRange)r changeInLength:(NSInteger)d
{
    out(@"  did process: mask %lu range %@ change %ld", (unsigned long)m, NSStringFromRange(r), (long)d);
}
@end

static void
lines_of(NSLayoutManager *lm)
{
    [lm enumerateLineFragmentsForGlyphRange:NSMakeRange(0, lm.numberOfGlyphs)
                                 usingBlock:^(NSRect rect, NSRect used, NSTextContainer *c, NSRange g, BOOL *stop) {
                                   out(@"  line %@ rect %@ used %@", NSStringFromRange(g), rect3(rect), rect3(used));
                                 }];
}

static void
test_text_system(void)
{
    out(@"[text system]");
    if (!roboto)
        return;
    NSFont *f = [roboto fontWithSize:12];
    NSTextStorage *ts = [[NSTextStorage alloc]
        initWithString:@"Hello world. The quick brown fox jumps over the lazy dog.\nSecond paragraph.\n"
            attributes:@{NSFontAttributeName : f}];
    out(@"storage: %@ length %lu", chain(ts), (unsigned long)ts.length);
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(150, 1000)];
    out(@"container: size %@ padding %g simple %d lines %lu mode %ld tracks %d %d", NSStringFromSize(tc.size),
        tc.lineFragmentPadding, tc.isSimpleRectangularTextContainer, (unsigned long)tc.maximumNumberOfLines,
        (long)tc.lineBreakMode, tc.widthTracksTextView, tc.heightTracksTextView);
    out(@"default container size %@", NSStringFromSize([NSTextContainer new].size));
    NSLayoutManager *lm = [NSLayoutManager new];
    out(@"layout manager: %@ fontLeading %d nonContiguous %d", chain(lm), lm.usesFontLeading, lm.allowsNonContiguousLayout);
    [lm addTextContainer:tc];
    [ts addLayoutManager:lm];
    out(@"wired: %d %d %lu", tc.layoutManager == lm, lm.textStorage == ts, (unsigned long)ts.layoutManagers.count);
    out(@"glyphs %lu range %@ used %@", (unsigned long)lm.numberOfGlyphs,
        NSStringFromRange([lm glyphRangeForTextContainer:tc]), rect3([lm usedRectForTextContainer:tc]));
    lines_of(lm);
    out(@"extra %@ used %@", rect3(lm.extraLineFragmentRect), rect3(lm.extraLineFragmentUsedRect));
    NSPoint l3 = [lm locationForGlyphAtIndex:3], l20 = [lm locationForGlyphAtIndex:20];
    out(@"location 3 {%@ %@} 20 {%@ %@}", r3(l3.x), r3(l3.y), r3(l20.x), r3(l20.y));
    NSRange er;
    NSRect lf = [lm lineFragmentRectForGlyphAtIndex:30 effectiveRange:&er];
    out(@"fragment of 30: %@ %@ used %@", rect3(lf), NSStringFromRange(er),
        rect3([lm lineFragmentUsedRectForGlyphAtIndex:30 effectiveRange:NULL]));
    out(@"bounding 0-5 %@", rect3([lm boundingRectForGlyphRange:NSMakeRange(0, 5) inTextContainer:tc]));
    out(@"bounding 20-10 %@", rect3([lm boundingRectForGlyphRange:NSMakeRange(20, 10) inTextContainer:tc]));
    out(@"bounding 60-3 %@", rect3([lm boundingRectForGlyphRange:NSMakeRange(60, 3) inTextContainer:tc]));
    CGFloat frac;
    NSUInteger ci = [lm characterIndexForPoint:NSMakePoint(30, 20) inTextContainer:tc fractionOfDistanceBetweenInsertionPoints:&frac];
    out(@"character at (30,20) %lu fraction %.2f", (unsigned long)ci, frac);
    out(@"glyph at (30,20) %lu, at (2,2) %lu, at (1000,1000) %lu", (unsigned long)[lm glyphIndexForPoint:NSMakePoint(30, 20) inTextContainer:tc],
        (unsigned long)[lm glyphIndexForPoint:NSMakePoint(2, 2) inTextContainer:tc],
        (unsigned long)[lm glyphIndexForPoint:NSMakePoint(1000, 1000) inTextContainer:tc]);
    out(@"glyphs for rect (0,15,10,20) %@", NSStringFromRange([lm glyphRangeForBoundingRect:NSMakeRect(0, 15, 10, 20) inTextContainer:tc]));
    out(@"default line height %g %g baseline %g", [lm defaultLineHeightForFont:f], [lm defaultLineHeightForFont:roboto],
        [lm defaultBaselineOffsetForFont:f]);
    out(@"glyph 0 %u, character of glyph 5 %lu, glyph of character 5 %lu", (unsigned)[lm CGGlyphAtIndex:0],
        (unsigned long)[lm characterIndexForGlyphAtIndex:5], (unsigned long)[lm glyphIndexForCharacterAtIndex:5]);
    out(@"container of glyph 10: %d", [lm textContainerForGlyphAtIndex:10 effectiveRange:NULL] == tc);

    EditLog *log = [EditLog new];
    ts.delegate = log;
    out(@"replace:");
    [ts replaceCharactersInRange:NSMakeRange(0, 5) withString:@"Howdy there"];
    out(@"batch:");
    [ts beginEditing];
    [ts addAttribute:NSKernAttributeName value:@1 range:NSMakeRange(0, 3)];
    [ts replaceCharactersInRange:NSMakeRange(10, 1) withString:@""];
    [ts endEditing];
    out(@"after: mask %lu change %ld", (unsigned long)ts.editedMask, (long)ts.changeInLength);
    out(@"relaid: range %@ used %@", NSStringFromRange([lm glyphRangeForTextContainer:tc]), rect3([lm usedRectForTextContainer:tc]));
    lines_of(lm);

    /* Two containers: the text flows from the first into the second. */
    NSLayoutManager *two = [NSLayoutManager new];
    NSTextContainer *a = [[NSTextContainer alloc] initWithSize:NSMakeSize(150, 30)];
    NSTextContainer *b = [[NSTextContainer alloc] initWithSize:NSMakeSize(200, 100)];
    [two addTextContainer:a];
    [two addTextContainer:b];
    [ts addLayoutManager:two];
    out(@"two containers: %@ %@ used %@ %@", NSStringFromRange([two glyphRangeForTextContainer:a]),
        NSStringFromRange([two glyphRangeForTextContainer:b]), rect3([two usedRectForTextContainer:a]),
        rect3([two usedRectForTextContainer:b]));
    a.size = NSMakeSize(300, 30);
    out(@"wider first: %@ %@", NSStringFromRange([two glyphRangeForTextContainer:a]),
        NSStringFromRange([two glyphRangeForTextContainer:b]));
    [ts removeLayoutManager:two];
    out(@"removed: %lu %d", (unsigned long)ts.layoutManagers.count, two.textStorage == nil);

    NSTextStorage *empty = [NSTextStorage new];
    NSLayoutManager *el = [NSLayoutManager new];
    NSTextContainer *ec = [[NSTextContainer alloc] initWithSize:NSMakeSize(100, 100)];
    [el addTextContainer:ec];
    [empty addLayoutManager:el];
    out(@"empty: used %@ extra %@ glyphs %@", rect3([el usedRectForTextContainer:ec]), rect3(el.extraLineFragmentRect),
        NSStringFromRange([el glyphRangeForTextContainer:ec]));
    NSTextContainer *ta = [[NSTextContainer alloc] initWithSize:NSMakeSize(150, 300)];
    ta.lineFragmentPadding = 3;
    ta.widthTracksTextView = YES;
    out(@"archive container: %@", archived(ta));
}

#pragma mark - Measuring

static NSString *
measure(NSString *s, NSDictionary *attrs, NSSize size, NSStringDrawingOptions options)
{
    NSRect r = [s boundingRectWithSize:size options:options attributes:attrs context:nil];
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:s attributes:attrs];
    NSRect ra = [as boundingRectWithSize:size options:options context:nil];
    return NSEqualRects(r, ra) ? rect3(r) : [NSString stringWithFormat:@"%@ (attributed %@)", rect3(r), rect3(ra)];
}

static void
test_measuring(void)
{
    out(@"[measuring]");
    if (!roboto)
        return;
    NSDictionary *a = @{NSFontAttributeName : roboto};
    NSDictionary *a12 = @{NSFontAttributeName : [roboto fontWithSize:12]};
    NSArray *strings = @[ @"", @"Hello", @"Hello World", @"  spaces  ", @"line one\nline two", @"fi ffl AVATAR", @"x\n" ];
    for (NSString *s in strings) {
        NSAttributedString *as = [[NSAttributedString alloc] initWithString:s attributes:a];
        out(@"size \"%@\": %@ attributed %@", [s stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"],
            size3([s sizeWithAttributes:a]), size3(as.size));
    }
    NSString *para = @"The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs.";
    NSStringDrawingOptions opts[] = {0, NSStringDrawingUsesLineFragmentOrigin,
                                     NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading,
                                     NSStringDrawingTruncatesLastVisibleLine | NSStringDrawingUsesLineFragmentOrigin};
    for (size_t i = 0; i < sizeof opts / sizeof opts[0]; i++) {
        out(@"options %lu wide: %@", (unsigned long)opts[i], measure(para, a12, NSMakeSize(1000, 1000), opts[i]));
        out(@"options %lu 150: %@", (unsigned long)opts[i], measure(para, a12, NSMakeSize(150, 1000), opts[i]));
        if (opts[i] & NSStringDrawingTruncatesLastVisibleLine) {
            NSRect r = [para boundingRectWithSize:NSMakeSize(150, 40) options:opts[i] attributes:a12 context:nil];
            out(@"options %lu 150x40: height %g fits %d", (unsigned long)opts[i], r.size.height,
                r.size.width <= 150 && r.size.width > 100);
        } else
            out(@"options %lu 150x40: %@", (unsigned long)opts[i], measure(para, a12, NSMakeSize(150, 40), opts[i]));
        out(@"options %lu two lines: %@", (unsigned long)opts[i], measure(@"one\ntwo", a12, NSMakeSize(0, 0), opts[i]));
    }
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineSpacing = 4;
    out(@"lineSpacing 4: %@", measure(para, @{NSFontAttributeName : roboto, NSParagraphStyleAttributeName : ps},
                                      NSMakeSize(150, 1000), NSStringDrawingUsesLineFragmentOrigin));
    ps = [NSMutableParagraphStyle new];
    ps.minimumLineHeight = 40;
    out(@"minimumLineHeight 40: %@", measure(@"a\nb", @{NSFontAttributeName : roboto, NSParagraphStyleAttributeName : ps},
                                             NSMakeSize(150, 1000), NSStringDrawingUsesLineFragmentOrigin));
    ps = [NSMutableParagraphStyle new];
    ps.paragraphSpacing = 10;
    out(@"paragraphSpacing 10: %@", measure(@"a\nb", @{NSFontAttributeName : roboto, NSParagraphStyleAttributeName : ps},
                                            NSMakeSize(150, 1000), NSStringDrawingUsesLineFragmentOrigin));
    ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    /* Truncated lines: one line, within the width (Apple's also tightens the text first). */
    NSRect tr = [para boundingRectWithSize:NSMakeSize(150, 1000)
                                   options:NSStringDrawingUsesLineFragmentOrigin
                                attributes:@{NSFontAttributeName : roboto, NSParagraphStyleAttributeName : ps}
                                   context:nil];
    out(@"truncating tail: height %g fits %d", tr.size.height, tr.size.width <= 150 && tr.size.width > 100);
    out(@"kern 2: %@", size3([@"Hello" sizeWithAttributes:@{NSFontAttributeName : roboto, NSKernAttributeName : @2}]));
    out(@"no font (Helvetica 12) height: %@", r3([@"Hello" sizeWithAttributes:@{}].height));
    out(@"no font nil attributes height: %@", r3([@"Hello" sizeWithAttributes:nil].height));
    NSMutableAttributedString *mixed = [[NSMutableAttributedString alloc] initWithString:@"Small BIG" attributes:a12];
    [mixed addAttribute:NSFontAttributeName value:roboto range:NSMakeRange(6, 3)];
    out(@"mixed sizes: %@", size3(mixed.size));
    NSStringDrawingContext *ctx = [NSStringDrawingContext new];
    NSRect r = [para boundingRectWithSize:NSMakeSize(150, 1000) options:NSStringDrawingUsesLineFragmentOrigin attributes:a12
                                  context:ctx];
    out(@"context: actualScale %g totalBounds %@ (rect %@)", ctx.actualScaleFactor, rect3(ctx.totalBounds), rect3(r));
}

#pragma mark - Drawing

#define DRAW_W 160
#define DRAW_H 64

typedef void (*DrawFn)(void);
typedef struct {
    const char *name;
    BOOL flipped;
    DrawFn fn;
} Scene;

static void
d_point(void)
{
    [@"Hello, World" drawAtPoint:NSMakePoint(4, 20) withAttributes:@{NSFontAttributeName : roboto}];
}

static void
d_rect(void)
{
    [@"The quick brown fox jumps over the lazy dog" drawInRect:NSMakeRect(4, 4, 150, 56)
                                                withAttributes:@{NSFontAttributeName : [roboto fontWithSize:14]}];
}

static void
d_centered(void)
{
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    [@"centred\ntext" drawInRect:NSMakeRect(0, 0, DRAW_W, DRAW_H)
                  withAttributes:@{NSFontAttributeName : [roboto fontWithSize:18], NSParagraphStyleAttributeName : ps}];
}

static void
d_right(void)
{
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentRight;
    [@"right" drawInRect:NSMakeRect(0, 10, DRAW_W - 4, 40)
          withAttributes:@{NSFontAttributeName : roboto, NSParagraphStyleAttributeName : ps}];
}

static void
d_options(void)
{
    [@"Line fragment origin, wrapped to the width" drawWithRect:NSMakeRect(4, 4, 150, 50)
                                                        options:NSStringDrawingUsesLineFragmentOrigin
                                                     attributes:@{NSFontAttributeName : [roboto fontWithSize:13]}
                                                        context:nil];
}

static void
d_baseline(void)
{
    [@"Baseline origin" drawWithRect:NSMakeRect(4, 30, 150, 20)
                             options:0
                          attributes:@{NSFontAttributeName : [roboto fontWithSize:16]}
                             context:nil];
}

static void
d_attributed(void)
{
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:@"Under and kern"
                                                                          attributes:@{NSFontAttributeName : roboto}];
    [s addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:NSMakeRange(0, 5)];
    [s addAttribute:NSKernAttributeName value:@3 range:NSMakeRange(10, 4)];
    [s drawAtPoint:NSMakePoint(4, 20)];
}

static void
d_truncated(void)
{
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    ps.allowsDefaultTighteningForTruncation = NO; /* (Apple's tightening isn't Finch's) */
    [@"This line is far too long to fit" drawInRect:NSMakeRect(4, 20, 120, 30)
                                     withAttributes:@{NSFontAttributeName : roboto, NSParagraphStyleAttributeName : ps}];
}

static void
d_strike(void)
{
    [@"Struck" drawAtPoint:NSMakePoint(10, 20)
            withAttributes:@{NSFontAttributeName : roboto, NSStrikethroughStyleAttributeName : @(NSUnderlineStyleSingle)}];
}

static void
d_baseline_offset(void)
{
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc] initWithString:@"x2 up"
                                                                          attributes:@{NSFontAttributeName : roboto}];
    [s addAttribute:NSBaselineOffsetAttributeName value:@8 range:NSMakeRange(1, 1)];
    [s drawAtPoint:NSMakePoint(10, 14)];
}

static void
d_shadowless_clip(void)
{
    [@"Clipped text in a small rect" drawInRect:NSMakeRect(10, 20, 60, 16) withAttributes:@{NSFontAttributeName : roboto}];
}

static void
d_layout_manager(void)
{
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
        initWithString:@"Laid out by a layout manager, in a text container."
            attributes:@{NSFontAttributeName : [roboto fontWithSize:14]}];
    [s addAttribute:NSUnderlineStyleAttributeName value:@(NSUnderlineStyleSingle) range:NSMakeRange(0, 8)];
    NSTextStorage *ts = [[NSTextStorage alloc] initWithAttributedString:s];
    NSLayoutManager *lm = [NSLayoutManager new];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(150, 60)];
    [lm addTextContainer:tc];
    [ts addLayoutManager:lm];
    [lm drawGlyphsForGlyphRange:[lm glyphRangeForTextContainer:tc] atPoint:NSMakePoint(2, 3)];
}

static const Scene scenes[] = {
    {"drawAtPoint", NO, d_point},
    {"drawAtPoint flipped", YES, d_point},
    {"drawInRect wraps", NO, d_rect},
    {"drawInRect wraps flipped", YES, d_rect},
    {"centred", NO, d_centered},
    {"centred flipped", YES, d_centered},
    {"right aligned", NO, d_right},
    {"drawWithRect line fragment origin", NO, d_options},
    {"drawWithRect line fragment origin flipped", YES, d_options},
    {"drawWithRect baseline", NO, d_baseline},
    {"drawWithRect baseline flipped", YES, d_baseline},
    {"underline and kern", NO, d_attributed},
    {"underline and kern flipped", YES, d_attributed},
    {"truncated", NO, d_truncated},
    {"strikethrough", NO, d_strike},
    {"baseline offset", NO, d_baseline_offset},
    {"clipped to rect", NO, d_shadowless_clip},
    {"layout manager, flipped", YES, d_layout_manager},
};
#define NSCENES (sizeof scenes / sizeof scenes[0])

static unsigned char *
render(const Scene *s)
{
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate(NULL, DRAW_W, DRAW_H, 8, DRAW_W * 4, rgb, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(rgb);
    CGContextSetRGBFillColor(cg, 1, 1, 1, 1);
    CGContextFillRect(cg, CGRectMake(0, 0, DRAW_W, DRAW_H));
    /* Apple's font smoothing thickens glyphs, and without it glyphs snap to
     * whole pixels; Finch's CoreGraphics does neither. Glyphs at their exact
     * positions, unsmoothed, on both. */
    CGContextSetShouldSmoothFonts(cg, false);
    CGContextSetAllowsFontSmoothing(cg, false);
    CGContextSetAllowsFontSubpixelPositioning(cg, true);
    CGContextSetShouldSubpixelPositionFonts(cg, true);
    CGContextSetAllowsFontSubpixelQuantization(cg, false);
    CGContextSetShouldSubpixelQuantizeFonts(cg, false);
    if (s->flipped) {
        CGContextTranslateCTM(cg, 0, DRAW_H);
        CGContextScaleCTM(cg, 1, -1);
    }
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithCGContext:cg flipped:s->flipped];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    s->fn();
    [NSGraphicsContext restoreGraphicsState];
    unsigned char *px = malloc(DRAW_W * DRAW_H * 4);
    memcpy(px, CGBitmapContextGetData(cg), DRAW_W * DRAW_H * 4);
    CGContextRelease(cg);
    return px;
}

/* As finch-cg-draw-test compares text: exact (within 2) where the reference
 * is flat, a bounded mean difference on edges. */
static int
compare(const char *name, const unsigned char *ref, const unsigned char *got)
{
    int interior_max = 0, edges = 0, bad = 0, ink_ref = 0, ink_got = 0;
    double edge_sum = 0;
    for (int y = 0; y < DRAW_H; y++)
        for (int x = 0; x < DRAW_W; x++) {
            const unsigned char *r = ref + 4 * (y * DRAW_W + x), *g = got + 4 * (y * DRAW_W + x);
            ink_ref += r[0] < 128;
            ink_got += g[0] < 128;
            int flat = 1;
            for (int dy = -1; dy <= 1 && flat; dy++)
                for (int dx = -1; dx <= 1 && flat; dx++) {
                    int nx = x + dx, ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= DRAW_W || ny >= DRAW_H)
                        continue;
                    flat = !memcmp(r, ref + 4 * (ny * DRAW_W + nx), 4);
                }
            int diff = 0;
            for (int k = 0; k < 4; k++)
                diff = MAX(diff, abs(r[k] - g[k]));
            if (flat) {
                interior_max = MAX(interior_max, diff);
            } else {
                edges++;
                edge_sum += diff;
                bad += diff > 128;
            }
        }
    double edge_mean = edges ? edge_sum / edges : 0;
    int ok = interior_max <= 2 && edge_mean <= 20 && bad <= edges / 50 + 1;
    if (ok)
        out(@"%s: ok", name);
    else
        out(@"%s: DIFFERS (flat max %d, edge mean %.1f, edge outliers %d of %d, ink %d vs %d)", name, interior_max,
            edge_mean, bad, edges, ink_got, ink_ref);
    return ok;
}

/* For looking at differences: the render and its reference as PPM images. */
static const char *dump_dir;

static void
dump(const char *name, const char *suffix, const unsigned char *px)
{
    if (!dump_dir)
        return;
    char path[1024];
    snprintf(path, sizeof path, "%s/%s-%s.ppm", dump_dir, name, suffix);
    for (char *p = path + strlen(dump_dir) + 1; *p; p++)
        if (*p == ' ' || *p == ',')
            *p = '_';
    FILE *f = fopen(path, "wb");
    if (!f)
        return;
    fprintf(f, "P6 %d %d 255\n", DRAW_W, DRAW_H);
    for (int i = 0; i < DRAW_W * DRAW_H; i++)
        fwrite(px + 4 * i, 1, 3, f);
    fclose(f);
}

static int
test_drawing(const char *refPath, const char *writePath)
{
    out(@"[drawing]");
    if (!roboto) {
        out(@"no Roboto");
        return 1;
    }
    size_t one = DRAW_W * DRAW_H * 4, total = one * NSCENES;
    if (writePath) {
        unsigned char *all = malloc(total);
        for (size_t i = 0; i < NSCENES; i++) {
            unsigned char *px = render(&scenes[i]);
            memcpy(all + i * one, px, one);
            free(px);
        }
        uLongf zlen = compressBound(total);
        unsigned char *z = malloc(zlen);
        compress2(z, &zlen, all, total, 9);
        FILE *f = fopen(writePath, "wb");
        fwrite(z, 1, zlen, f);
        fclose(f);
        fprintf(stderr, "wrote %zu scenes (%lu bytes)\n", NSCENES, (unsigned long)zlen);
        return 0;
    }
    FILE *f = fopen(refPath, "rb");
    if (!f) {
        out(@"no reference at %s", refPath);
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long zlen = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *z = malloc((size_t)zlen), *all = malloc(total);
    fread(z, 1, (size_t)zlen, f);
    fclose(f);
    uLongf len = total;
    if (uncompress(all, &len, z, (uLong)zlen) != Z_OK || len != total) {
        out(@"reference doesn't match these scenes: regenerate it with --write");
        return 1;
    }
    int failures = 0;
    for (size_t i = 0; i < NSCENES; i++) {
        unsigned char *px = render(&scenes[i]);
        failures += !compare(scenes[i].name, all + i * one, px);
        dump(scenes[i].name, "got", px);
        dump(scenes[i].name, "ref", all + i * one);
        free(px);
    }
    return failures;
}

static NSFont *
load_roboto(const char *path)
{
    const char *paths[] = {path, "/usr/local/share/finch/test-fonts/Roboto-Regular.ttf",
                           "build/src/skia/resources/fonts/Roboto-Regular.ttf"};
    for (size_t i = 0; i < 3; i++) {
        if (!paths[i] || access(paths[i], R_OK))
            continue;
        NSURL *u = [NSURL fileURLWithPath:@(paths[i])];
        CTFontManagerRegisterFontsForURL((__bridge CFURLRef)u, kCTFontManagerScopeProcess, NULL);
        return [NSFont fontWithName:@"Roboto-Regular" size:24];
    }
    return nil;
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        const char *font = NULL, *ref = NULL, *write = NULL;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--write") && i + 1 < argc)
                write = argv[++i];
            else if (!strcmp(argv[i], "--dump") && i + 1 < argc)
                dump_dir = argv[++i];
            else if (strstr(argv[i], ".ttf"))
                font = argv[i];
            else
                ref = argv[i];
        }
        printf("UIFoundation: %s\n", class_getImageName([NSFont class]));
        roboto = load_roboto(font);
        if (write)
            return test_drawing(NULL, write);
        test_constants();
        test_font_classes();
        test_ui_fonts();
        test_roboto();
        test_descriptors();
        test_paragraph_styles();
        test_tabs_and_lists();
        test_shadows();
        test_misc();
        test_measuring();
        test_text_system();
        test_drawing(ref ? ref : "/usr/local/share/finch/uifoundation-reference.bin", NULL);
    }
    return 0;
}
