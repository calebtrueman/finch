/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-appkit-controls-test: AppKit's controls and cells without a screen:
 * cell state and values and their conversions, state cycling, action
 * routing, buttons and their types, text fields, sliders, steppers,
 * progress indicators, segmented controls, colour wells, image views, boxes,
 * level indicators, and a nib full of controls (controls-test.xib, compiled
 * by ibtool). Prints everything; run it against Apple's AppKit and Finch's
 * (DYLD_FRAMEWORK_PATH) and diff all but the first line, which is where
 * NSButton came from. Geometry that depends on Finch's own look (title
 * widths, bezel insets) is not printed.
 *
 *   finch-appkit-controls-test [path to controls-test.nib]
 */
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static void out(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void
out(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", [s UTF8String]);
}

/* Print an expression's value, or the exception it raises. */
#define SHOW(fmt, expr)                                                         \
    do {                                                                        \
        @try {                                                                  \
            out(@"  %s: " fmt, #expr, expr);                                    \
        } @catch (NSException * e) {                                            \
            out(@"  %s: raises %@", #expr, e.name);                             \
        }                                                                       \
    } while (0)

#define DO(stmt)                                                                \
    do {                                                                        \
        @try {                                                                  \
            stmt;                                                               \
        } @catch (NSException * e) {                                            \
            out(@"  %s: raises %@", #stmt, e.name);                             \
        }                                                                       \
    } while (0)

static NSMutableArray<NSString *> *log_;

static void
flush_log(NSString *label)
{
    out(@"%@: %@", label, [log_ componentsJoinedByString:@"; "]);
    [log_ removeAllObjects];
}

static NSString *
color_desc(NSColor *c)
{
    if (!c)
        return @"nil";
    if (c.type == NSColorTypeCatalog)
        return [NSString stringWithFormat:@"%@/%@", c.catalogNameComponent, c.colorNameComponent];
    NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!s)
        return @"(no sRGB)";
    return [NSString stringWithFormat:@"rgba %.3f %.3f %.3f %.3f", s.redComponent, s.greenComponent, s.blueComponent,
                                      s.alphaComponent];
}

static NSString *
font_desc(NSFont *f)
{
    if (!f)
        return @"nil";
    /* Finch's system font is its own (Inter); compare with what the system font is */
    if ([f.fontName isEqual:[NSFont systemFontOfSize:f.pointSize].fontName])
        return [NSString stringWithFormat:@"system %g", f.pointSize];
    if ([f.fontName isEqual:[NSFont boldSystemFontOfSize:f.pointSize].fontName])
        return [NSString stringWithFormat:@"bold system %g", f.pointSize];
    return [NSString stringWithFormat:@"%@ %g", f.fontName, f.pointSize];
}

static NSString *
obj_desc(id o)
{
    if (!o)
        return @"nil";
    if ([o isKindOfClass:[NSString class]])
        return [NSString stringWithFormat:@"'%@' (string)", o];
    if ([o isKindOfClass:[NSNumber class]])
        return [NSString stringWithFormat:@"%@ (number)", o];
    if ([o isKindOfClass:[NSAttributedString class]])
        return [NSString stringWithFormat:@"'%@' (attributed)", [o string]];
    if ([o isKindOfClass:[NSImage class]])
        return [NSString stringWithFormat:@"image %@", NSStringFromSize([o size])];
    if ([o isKindOfClass:[NSColor class]])
        return [NSString stringWithFormat:@"color %@", color_desc(o)];
    return [NSString stringWithFormat:@"a %@", [o class]];
}

static const char *
sel_name(SEL s)
{
    return s ? sel_getName(s) : "(null)";
}

/* nil, hidden from the nullability checks */
static NSString *
nil_string(void)
{
    return nil;
}

#pragma mark - Targets

@interface Target : NSObject
@property (copy) NSString *name;
@end

@implementation Target
- (void)log:(SEL)sel sender:(id)sender
{
    NSString *what = @"";
    if ([sender respondsToSelector:@selector(objectValue)])
        what = obj_desc([sender objectValue]);
    [log_ addObject:[NSString stringWithFormat:@"%@ %s from %@ %@", self.name, sel_getName(sel), [sender class], what]];
}
- (void)act:(id)sender { [self log:_cmd sender:sender]; }
- (void)other:(id)sender { [self log:_cmd sender:sender]; }
- (void)ok:(id)sender { [self log:_cmd sender:sender]; }
- (void)cancel:(id)sender { [self log:_cmd sender:sender]; }
- (void)check:(id)sender { [self log:_cmd sender:sender]; }
- (void)radio:(id)sender { [self log:_cmd sender:sender]; }
- (void)field:(id)sender { [self log:_cmd sender:sender]; }
- (void)slide:(id)sender { [self log:_cmd sender:sender]; }
- (void)step:(id)sender { [self log:_cmd sender:sender]; }
- (void)segment:(id)sender { [self log:_cmd sender:sender]; }
@end

@interface Responder : NSView
@end

@implementation Responder
- (BOOL)acceptsFirstResponder { return YES; }
- (void)act:(id)sender
{
    [log_ addObject:[NSString stringWithFormat:@"first responder act: from %@", [sender class]]];
}
@end

@interface Owner : Target
@property (strong) NSWindow *window;
@property (strong) NSTextField *field;
@property (strong) NSButton *ok;
@end

@implementation Owner
@end

/* A cell subclass to see which methods the control calls. */
@interface MyCell : NSActionCell
@end

@implementation MyCell
@end

@interface MyControl : NSControl
@end

@implementation MyControl
+ (Class)cellClass { return [MyCell class]; }
@end

#pragma mark - Dumping

static void
dump_cell(NSCell *c)
{
    out(@"  cell %@", [c class]);
    SHOW(@"%ld", (long)[c type]);
    SHOW(@"%ld", (long)[c state]);
    SHOW(@"%d", [c isEnabled]);
    SHOW(@"%d", [c isBordered]);
    SHOW(@"%d", [c isBezeled]);
    SHOW(@"%d", [c isEditable]);
    SHOW(@"%d", [c isSelectable]);
    SHOW(@"%d", [c isScrollable]);
    SHOW(@"%d", [c wraps]);
    SHOW(@"%ld", (long)[c alignment]);
    SHOW(@"%ld", (long)[c lineBreakMode]);
    SHOW(@"%d", [c truncatesLastVisibleLine]);
    SHOW(@"%ld", (long)[c controlSize]);
    SHOW(@"%d", [c isContinuous]);
    SHOW(@"%@", font_desc([c font]));
    if (![[c objectValue] isKindOfClass:[NSImage class]])
        SHOW(@"'%@'", [c stringValue]);
    SHOW(@"%@", obj_desc([c objectValue]));
    SHOW(@"%ld", (long)[c tag]);
    SHOW(@"%s", sel_name([c action]));
    SHOW(@"%@", [[c target] class]);
    SHOW(@"%d", [c allowsMixedState]);
    SHOW(@"%ld", (long)[c nextState]);
    SHOW(@"%d", [c isHighlighted]);
    SHOW(@"%d", [c refusesFirstResponder]);
    SHOW(@"%d", [c acceptsFirstResponder]);
    SHOW(@"%d", [c showsFirstResponder]);
    SHOW(@"%ld", (long)[c focusRingType]);
    SHOW(@"%d", [c sendsActionOnEndEditing]);
    SHOW(@"%d", [c allowsUndo]);
    SHOW(@"%d", [c importsGraphics]);
    SHOW(@"%d", [c allowsEditingTextAttributes]);
    SHOW(@"%d", [c usesSingleLineMode]);
    SHOW(@"%ld", (long)[c baseWritingDirection]);
    SHOW(@"%d", [c isOpaque]);
    SHOW(@"'%@'", [c keyEquivalent]);
    SHOW(@"%@", obj_desc([c image]));
    if (![[c objectValue] isKindOfClass:[NSImage class]])
        SHOW(@"'%@'", [c title]);
    SHOW(@"%@", [[c formatter] class]);
    SHOW(@"%@", [[c controlView] class]);
    SHOW(@"%ld", (long)[c cellAttribute:NSCellHighlighted]);
    SHOW(@"%ld", (long)[c cellAttribute:NSPushInCell]);
    SHOW(@"%ld", (long)[c cellAttribute:NSChangeGrayCell]);
    if ([c isKindOfClass:[NSButtonCell class]]) {
        NSButtonCell *b = (NSButtonCell *)c;
        SHOW(@"%ld", (long)[b highlightsBy]);
        SHOW(@"%ld", (long)[b showsStateBy]);
        SHOW(@"%ld", (long)[b bezelStyle]);
        SHOW(@"%ld", (long)[b imagePosition]);
        SHOW(@"%ld", (long)[b imageScaling]);
        SHOW(@"%d", [b isTransparent]);
        SHOW(@"'%@'", [b alternateTitle]);
        SHOW(@"%@", obj_desc([b alternateImage]));
        SHOW(@"%lx", (unsigned long)[b keyEquivalentModifierMask]);
        SHOW(@"%d", [b imageDimsWhenDisabled]);
        SHOW(@"%d", [b showsBorderOnlyWhileMouseInside]);
        SHOW(@"'%@'", [[b attributedTitle] string]);
        float delay = 0, interval = 0;
        [b getPeriodicDelay:&delay interval:&interval];
        out(@"  periodic %g %g", delay, interval);
    }
    if ([c isKindOfClass:[NSTextFieldCell class]]) {
        NSTextFieldCell *t = (NSTextFieldCell *)c;
        SHOW(@"%d", [t drawsBackground]);
        SHOW(@"%@", color_desc([t backgroundColor]));
        SHOW(@"%@", color_desc([t textColor]));
        SHOW(@"%ld", (long)[t bezelStyle]);
        SHOW(@"'%@'", [t placeholderString]);
        SHOW(@"%@", [t allowedInputSourceLocales]);
    }
    if ([c isKindOfClass:[NSSecureTextFieldCell class]])
        SHOW(@"%d", [(NSSecureTextFieldCell *)c echosBullets]);
    if ([c isKindOfClass:[NSSliderCell class]]) {
        NSSliderCell *s = (NSSliderCell *)c;
        SHOW(@"%g", [s minValue]);
        SHOW(@"%g", [s maxValue]);
        SHOW(@"%g", [s doubleValue]);
        SHOW(@"%g", [s altIncrementValue]);
        SHOW(@"%ld", (long)[s numberOfTickMarks]);
        SHOW(@"%ld", (long)[s tickMarkPosition]);
        SHOW(@"%d", [s allowsTickMarkValuesOnly]);
        SHOW(@"%ld", (long)[s sliderType]);
        SHOW(@"%d", [s isVertical]);
    }
    if ([c isKindOfClass:[NSStepperCell class]]) {
        NSStepperCell *s = (NSStepperCell *)c;
        SHOW(@"%g", [s minValue]);
        SHOW(@"%g", [s maxValue]);
        SHOW(@"%g", [s increment]);
        SHOW(@"%d", [s valueWraps]);
        SHOW(@"%d", [s autorepeat]);
    }
    if ([c isKindOfClass:[NSImageCell class]]) {
        NSImageCell *i = (NSImageCell *)c;
        SHOW(@"%ld", (long)[i imageAlignment]);
        SHOW(@"%ld", (long)[i imageScaling]);
        SHOW(@"%ld", (long)[i imageFrameStyle]);
    }
    if ([c isKindOfClass:[NSLevelIndicatorCell class]]) {
        NSLevelIndicatorCell *l = (NSLevelIndicatorCell *)c;
        SHOW(@"%ld", (long)[l levelIndicatorStyle]);
        SHOW(@"%g", [l minValue]);
        SHOW(@"%g", [l maxValue]);
        SHOW(@"%g", [l warningValue]);
        SHOW(@"%g", [l criticalValue]);
        SHOW(@"%ld", (long)[l numberOfTickMarks]);
        SHOW(@"%ld", (long)[l numberOfMajorTickMarks]);
        SHOW(@"%ld", (long)[l tickMarkPosition]);
    }
    if ([c isKindOfClass:[NSSegmentedCell class]]) {
        NSSegmentedCell *s = (NSSegmentedCell *)c;
        SHOW(@"%ld", (long)[s segmentCount]);
        SHOW(@"%ld", (long)[s selectedSegment]);
        SHOW(@"%ld", (long)[s trackingMode]);
        SHOW(@"%ld", (long)[s segmentStyle]);
        for (NSInteger i = 0; i < [s segmentCount]; i++)
            out(@"  segment %ld '%@' width %g selected %d enabled %d tag %ld tooltip %@", (long)i, [s labelForSegment:i],
                [s widthForSegment:i], [s isSelectedForSegment:i], [s isEnabledForSegment:i], (long)[s tagForSegment:i],
                [s toolTipForSegment:i]);
    }
}

/* Factories size controls to fit their titles, which depends on the font: print only their heights. */
static BOOL show_width = YES;

static void
dump_control(NSView *v)
{
    if (show_width)
        out(@"%@ frame %@ tag %ld", [v class], NSStringFromRect(v.frame), (long)v.tag);
    else
        out(@"%@ height %g tag %ld", [v class], v.frame.size.height, (long)v.tag);
    if (![v isKindOfClass:[NSControl class]]) {
        if ([v isKindOfClass:[NSProgressIndicator class]]) {
            NSProgressIndicator *p = (NSProgressIndicator *)v;
            SHOW(@"%ld", (long)[p style]);
            SHOW(@"%d", [p isIndeterminate]);
            SHOW(@"%d", [p isBezeled]);
            SHOW(@"%ld", (long)[p controlSize]);
            SHOW(@"%g", [p minValue]);
            SHOW(@"%g", [p maxValue]);
            SHOW(@"%g", [p doubleValue]);
            SHOW(@"%d", [p isDisplayedWhenStopped]);
            SHOW(@"%d", [p usesThreadedAnimation]);
            SHOW(@"%ld", (long)[p controlTint]);
        }
        if ([v isKindOfClass:[NSBox class]]) {
            NSBox *b = (NSBox *)v;
            SHOW(@"%ld", (long)[b boxType]);
            SHOW(@"%ld", (long)[b borderType]);
            SHOW(@"%ld", (long)[b titlePosition]);
            SHOW(@"'%@'", [b title]);
            SHOW(@"%@", font_desc([b titleFont]));
            SHOW(@"%@", NSStringFromSize([b contentViewMargins]));
            SHOW(@"%@", NSStringFromRect([[b contentView] frame]));
            SHOW(@"%d", [b isTransparent]);
            SHOW(@"%g", [b borderWidth]);
            SHOW(@"%g", [b cornerRadius]);
            SHOW(@"%@", color_desc([b borderColor]));
            SHOW(@"%@", color_desc([b fillColor]));
            SHOW(@"%lu", (unsigned long)[[[b contentView] subviews] count]);
            SHOW(@"%@", [[b titleCell] class]);
        }
        return;
    }
    NSControl *c = (NSControl *)v;
    SHOW(@"%d", [c isEnabled]);
    SHOW(@"%ld", (long)[c alignment]);
    SHOW(@"%@", font_desc([c font]));
    if (![[c objectValue] isKindOfClass:[NSImage class]])
        SHOW(@"'%@'", [c stringValue]);
    SHOW(@"%@", obj_desc([c objectValue]));
    SHOW(@"%d", [c intValue]);
    SHOW(@"%g", [c doubleValue]);
    SHOW(@"%s", sel_name([c action]));
    SHOW(@"%@", [[c target] class]);
    SHOW(@"%d", [c isContinuous]);
    SHOW(@"%ld", (long)[c controlSize]);
    SHOW(@"%d", [c refusesFirstResponder]);
    SHOW(@"%d", [c acceptsFirstResponder]);
    SHOW(@"%ld", (long)[c lineBreakMode]);
    SHOW(@"%d", [c usesSingleLineMode]);
    SHOW(@"%d", [c isHighlighted]);
    if ([c isKindOfClass:[NSButton class]]) {
        NSButton *b = (NSButton *)c;
        SHOW(@"'%@'", [b title]);
        SHOW(@"%ld", (long)[b state]);
        SHOW(@"%ld", (long)[b bezelStyle]);
        SHOW(@"%d", [b isBordered]);
        SHOW(@"'%@'", [b keyEquivalent]);
        SHOW(@"%lx", (unsigned long)[b keyEquivalentModifierMask]);
        SHOW(@"%d", [b allowsMixedState]);
    }
    if ([c isKindOfClass:[NSTextField class]]) {
        NSTextField *t = (NSTextField *)c;
        SHOW(@"%d", [t isEditable]);
        SHOW(@"%d", [t isSelectable]);
        SHOW(@"%d", [t isBezeled]);
        SHOW(@"%d", [t isBordered]);
        SHOW(@"%d", [t drawsBackground]);
        SHOW(@"%@", color_desc([t textColor]));
        SHOW(@"%@", color_desc([t backgroundColor]));
        SHOW(@"'%@'", [t placeholderString]);
        SHOW(@"%ld", (long)[t maximumNumberOfLines]);
        SHOW(@"%g", [t preferredMaxLayoutWidth]);
    }
    if ([c isKindOfClass:[NSColorWell class]]) {
        NSColorWell *w = (NSColorWell *)c;
        SHOW(@"%@", color_desc([w color]));
        SHOW(@"%d", [w isBordered]);
        SHOW(@"%d", [w isActive]);
    }
    if ([c isKindOfClass:[NSImageView class]]) {
        NSImageView *i = (NSImageView *)c;
        SHOW(@"%d", [i isEditable]);
        SHOW(@"%d", [i animates]);
        SHOW(@"%d", [i allowsCutCopyPaste]);
        SHOW(@"%@", obj_desc([i image]));
    }
    if ([c isKindOfClass:[NSSegmentedControl class]]) {
        NSSegmentedControl *s = (NSSegmentedControl *)c;
        SHOW(@"%ld", (long)[s segmentCount]);
        SHOW(@"%ld", (long)[s selectedSegment]);
        SHOW(@"%ld", (long)[s indexOfSelectedItem]);
        SHOW(@"%ld", (long)[s trackingMode]);
    }
    if ([c isKindOfClass:[NSSlider class]]) {
        NSSlider *s = (NSSlider *)c;
        SHOW(@"%d", [s isVertical]);
        SHOW(@"%g", [s minValue]);
        SHOW(@"%g", [s maxValue]);
    }
    if ([c cell])
        dump_cell([c cell]);
}

#pragma mark - Cells

static void
test_cells(void)
{
    out(@"== NSCell");
    NSCell *plain = [[NSCell alloc] init];
    dump_cell(plain);
    NSCell *text = [[NSCell alloc] initTextCell:@"Text"];
    dump_cell(text);
    NSCell *image = [[NSCell alloc] initImageCell:nil];
    dump_cell(image);
    NSImage *im = [[NSImage alloc] initWithSize:NSMakeSize(16, 12)];
    NSCell *withImage = [[NSCell alloc] initImageCell:im];
    out(@"image cell with an image");
    SHOW(@"%ld", (long)[withImage type]);
    SHOW(@"%@", obj_desc([withImage image]));
    SHOW(@"%@", NSStringFromSize([withImage cellSize]));
    DO([withImage setStringValue:@"x"]);
    SHOW(@"%ld", (long)[withImage type]);
    SHOW(@"'%@'", [withImage stringValue]);

    out(@"setters on a plain cell");
    NSCell *c = [[NSCell alloc] initTextCell:@""];
    DO([c setTag:3]);
    SHOW(@"%ld", (long)[c tag]);
    DO([c setAction:@selector(act:)]);
    SHOW(@"%s", sel_name([c action]));
    DO([c setTarget:c]);
    SHOW(@"%@", [[c target] class]);
    DO([c setEditable:YES]);
    SHOW(@"%d", [c isSelectable]);
    DO([c setEditable:NO]);
    SHOW(@"%d", [c isSelectable]);
    DO([c setSelectable:NO]);
    DO([c setEditable:YES]);
    DO([c setSelectable:NO]);
    SHOW(@"%d", [c isEditable]);
    SHOW(@"%d", [c isSelectable]);
    DO([c setBezeled:YES]);
    SHOW(@"%d", [c isBordered]);
    DO([c setBordered:YES]);
    SHOW(@"%d", [c isBezeled]);
    DO([c setScrollable:YES]);
    SHOW(@"%d", [c wraps]);
    DO([c setWraps:YES]);
    SHOW(@"%d", [c isScrollable]);
    SHOW(@"%ld", (long)[c lineBreakMode]);
    DO([c setLineBreakMode:NSLineBreakByTruncatingTail]);
    SHOW(@"%d", [c wraps]);
    SHOW(@"%d", [c isScrollable]);
    DO([c setLineBreakMode:NSLineBreakByCharWrapping]);
    SHOW(@"%d", [c wraps]);
    DO([c setAlignment:NSTextAlignmentRight]);
    SHOW(@"%ld", (long)[c alignment]);
    DO([c setControlSize:NSControlSizeSmall]);
    SHOW(@"%ld", (long)[c controlSize]);
    SHOW(@"%@", font_desc([c font]));
    DO([c setFont:[NSFont systemFontOfSize:20]]);
    SHOW(@"%@", font_desc([c font]));
    DO([c setTitle:@"Title"]);
    SHOW(@"'%@'", [c stringValue]);
    DO([c setContinuous:YES]);
    SHOW(@"%d", [c isContinuous]);
    SHOW(@"%ld", (long)[c sendActionOn:NSEventMaskLeftMouseDown]);
    SHOW(@"%ld", (long)[c sendActionOn:NSEventMaskLeftMouseUp]);
    SHOW(@"%d", [c isContinuous]);
    DO([c setHighlighted:YES]);
    SHOW(@"%d", [c isHighlighted]);
    DO([c setEnabled:NO]);
    SHOW(@"%d", [c isEnabled]);
    SHOW(@"%d", [c acceptsFirstResponder]);
    DO([c setEnabled:YES]);
    DO([c setRefusesFirstResponder:YES]);
    SHOW(@"%d", [c acceptsFirstResponder]);
    DO([c setCellAttribute:NSCellEditable to:1]);
    SHOW(@"%d", [c isEditable]);
    SHOW(@"%ld", (long)[c cellAttribute:NSCellDisabled]);
    SHOW(@"%ld", (long)[c cellAttribute:NSCellState]);
    DO([c setType:NSImageCellType]);
    SHOW(@"%ld", (long)[c type]);
    SHOW(@"%@", obj_desc([c image]));
    SHOW(@"'%@'", [c stringValue]);
    DO([c setType:NSNullCellType]);
    SHOW(@"%ld", (long)[c type]);
    SHOW(@"'%@'", [c stringValue]);
    DO([c setType:NSTextCellType]);
    SHOW(@"'%@'", [c stringValue]);
    DO([c setImage:im]);
    SHOW(@"%ld", (long)[c type]);
    DO([c setMnemonicLocation:2]);
    SHOW(@"%lu", (unsigned long)[c mnemonicLocation]);
    SHOW(@"'%@'", [c mnemonic]);
    DO([c setTitleWithMnemonic:@"Op&en"]);
    SHOW(@"'%@'", [c title]);
    SHOW(@"%lu", (unsigned long)[c mnemonicLocation]);

    out(@"== values");
    NSCell *v = [[NSCell alloc] initTextCell:@""];
    DO([v setIntValue:42]);
    SHOW(@"%@", obj_desc([v objectValue]));
    SHOW(@"'%@'", [v stringValue]);
    SHOW(@"%g", [v doubleValue]);
    DO([v setDoubleValue:3.75]);
    SHOW(@"%@", obj_desc([v objectValue]));
    SHOW(@"%d", [v intValue]);
    SHOW(@"%ld", (long)[v integerValue]);
    SHOW(@"%g", [v floatValue]);
    SHOW(@"'%@'", [v stringValue]);
    DO([v setDoubleValue:-2.5]);
    SHOW(@"%d", [v intValue]);
    DO([v setFloatValue:0.1f]);
    SHOW(@"'%@'", [v stringValue]);
    DO([v setIntegerValue:123456]);
    SHOW(@"'%@'", [v stringValue]);
    DO([v setIntegerValue:1234567890123]);
    SHOW(@"%d", [v intValue]);
    SHOW(@"%ld", (long)[v integerValue]);
    DO([v setStringValue:@"42abc"]);
    SHOW(@"%@", obj_desc([v objectValue]));
    SHOW(@"%d", [v intValue]);
    SHOW(@"%g", [v doubleValue]);
    DO([v setStringValue:@"  7.5e1 "]);
    SHOW(@"%g", [v floatValue]);
    SHOW(@"%d", [v intValue]);
    DO([v setStringValue:@"abc"]);
    SHOW(@"%d", [v intValue]);
    SHOW(@"%g", [v doubleValue]);
    DO([v setObjectValue:nil]);
    SHOW(@"%@", obj_desc([v objectValue]));
    SHOW(@"'%@'", [v stringValue]);
    DO([v setObjectValue:@[ @1 ]]);
    SHOW(@"'%@'", [v stringValue]);
    DO([v setObjectValue:[[NSAttributedString alloc] initWithString:@"attr"]]);
    SHOW(@"%@", obj_desc([v objectValue]));
    SHOW(@"'%@'", [v stringValue]);
    SHOW(@"'%@'", [[v attributedStringValue] string]);
    DO([v setStringValue:@"plain"]);
    SHOW(@"'%@'", [[v attributedStringValue] string]);
    NSDictionary *attrs = [[v attributedStringValue] attributesAtIndex:0 effectiveRange:NULL];
    out(@"  attributes: font %d colour %@ paragraph style %d", attrs[NSFontAttributeName] != nil,
        color_desc(attrs[NSForegroundColorAttributeName]), attrs[NSParagraphStyleAttributeName] != nil);
    SHOW(@"%@", font_desc([[v attributedStringValue] attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL]));
    SHOW(@"%d", [v hasValidObjectValue]);
    DO([v setStringValue:@""]);
    SHOW(@"%@", obj_desc([v objectValue]));
    DO([v setStringValue:(NSString *_Nonnull)(id)nil_string()]);
    SHOW(@"'%@'", [v stringValue]);

    NSCell *src = [[NSCell alloc] initTextCell:@"17.25"];
    DO([v takeIntValueFrom:src]);
    SHOW(@"%@", obj_desc([v objectValue]));
    DO([v takeDoubleValueFrom:src]);
    SHOW(@"%@", obj_desc([v objectValue]));
    DO([v takeStringValueFrom:src]);
    SHOW(@"%@", obj_desc([v objectValue]));
    DO([v takeObjectValueFrom:src]);
    SHOW(@"%@", obj_desc([v objectValue]));
    DO([v takeFloatValueFrom:src]);
    SHOW(@"%@", obj_desc([v objectValue]));
    DO([v takeIntegerValueFrom:src]);
    SHOW(@"%@", obj_desc([v objectValue]));

    out(@"formatter");
    NSNumberFormatter *nf = [[NSNumberFormatter alloc] init];
    nf.numberStyle = NSNumberFormatterDecimalStyle;
    nf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    NSCell *f = [[NSCell alloc] initTextCell:@""];
    f.formatter = nf;
    DO([f setStringValue:@"1,234.5"]);
    SHOW(@"%@", obj_desc([f objectValue]));
    SHOW(@"'%@'", [f stringValue]);
    DO([f setObjectValue:@9876.5]);
    SHOW(@"'%@'", [f stringValue]);
    SHOW(@"%d", [f intValue]);
    DO([f setStringValue:@"nonsense"]);
    SHOW(@"%@", obj_desc([f objectValue]));
    SHOW(@"'%@'", [f stringValue]);
    SHOW(@"%d", [f hasValidObjectValue]);
    DO([f setDoubleValue:5]);
    SHOW(@"'%@'", [f stringValue]);
    DO([f setIntValue:1000]);
    SHOW(@"'%@'", [f stringValue]);

    out(@"== states");
    NSCell *s = [[NSCell alloc] initTextCell:@"s"];
    NSInteger states[] = {1, 0, -1, 5, -3, 0};
    for (int i = 0; i < 6; i++) {
        [s setState:states[i]];
        out(@"  setState %ld -> %ld next %ld", (long)states[i], (long)[s state], (long)[s nextState]);
    }
    [s setAllowsMixedState:YES];
    for (int i = 0; i < 6; i++) {
        [s setState:states[i]];
        out(@"  mixed setState %ld -> %ld next %ld", (long)states[i], (long)[s state], (long)[s nextState]);
    }
    [s setState:0];
    NSMutableString *cycle = [NSMutableString string];
    for (int i = 0; i < 5; i++) {
        [s setNextState];
        [cycle appendFormat:@" %ld", (long)[s state]];
    }
    out(@"  mixed cycle%@", cycle);
    [s setAllowsMixedState:NO];
    [s setState:-1];
    out(@"  after disallowing mixed: %ld", (long)[s state]);
    cycle = [NSMutableString string];
    for (int i = 0; i < 3; i++) {
        [s setNextState];
        [cycle appendFormat:@" %ld", (long)[s state]];
    }
    out(@"  cycle%@", cycle);
    [s setState:1];
    SHOW(@"%@", obj_desc([s objectValue]));
    SHOW(@"%d", [s intValue]);

    out(@"== NSActionCell");
    NSActionCell *a = [[NSActionCell alloc] initTextCell:@"a"];
    dump_cell(a);
    Target *t = [Target new];
    t.name = @"t";
    a.target = t;
    a.action = @selector(act:);
    a.tag = 9;
    SHOW(@"%ld", (long)[a tag]);
    SHOW(@"%@", [[a target] class]);
    SHOW(@"%s", sel_name([a action]));
    DO([a performClick:nil]);
    flush_log(@"action cell performClick without a control");
    NSActionCell *a2 = [a copy];
    SHOW(@"%ld", (long)[a2 tag]);
    SHOW(@"%d", [a2 target] == t);
    SHOW(@"'%@'", [a2 stringValue]);

    out(@"== cell sizes");
    NSCell *sz = [[NSCell alloc] initTextCell:@""];
    SHOW(@"%@", NSStringFromSize([sz cellSize]));
    SHOW(@"%@", NSStringFromRect([sz drawingRectForBounds:NSMakeRect(0, 0, 100, 20)]));
    SHOW(@"%@", NSStringFromRect([sz titleRectForBounds:NSMakeRect(0, 0, 100, 20)]));
    SHOW(@"%@", NSStringFromRect([sz imageRectForBounds:NSMakeRect(0, 0, 100, 20)]));
    [sz setBordered:YES];
    SHOW(@"%@", NSStringFromRect([sz drawingRectForBounds:NSMakeRect(0, 0, 100, 20)]));
    [sz setBezeled:YES];
    SHOW(@"%@", NSStringFromRect([sz drawingRectForBounds:NSMakeRect(0, 0, 100, 20)]));
    NSCell *nul = [[NSCell alloc] init];
    [nul setType:NSNullCellType];
    SHOW(@"%@", NSStringFromSize([nul cellSize]));
    NSCell *imc = [[NSCell alloc] initImageCell:im];
    SHOW(@"%@", NSStringFromSize([imc cellSize]));
    SHOW(@"%@", NSStringFromSize([imc cellSizeForBounds:NSMakeRect(0, 0, 5, 5)]));
    [imc setBordered:YES];
    SHOW(@"%@", NSStringFromSize([imc cellSize]));
    [imc setBezeled:YES];
    SHOW(@"%@", NSStringFromSize([imc cellSize]));
}

#pragma mark - Controls

static void
test_controls(void)
{
    out(@"== NSControl");
    SHOW(@"%@", [NSControl cellClass]);
    NSControl *c = [[NSControl alloc] initWithFrame:NSMakeRect(0, 0, 100, 20)];
    SHOW(@"%@", [[c cell] class]);
    SHOW(@"%d", [c isEnabled]);
    SHOW(@"'%@'", [c stringValue]);
    SHOW(@"%@", obj_desc([c objectValue]));
    SHOW(@"%@", font_desc([c font]));
    SHOW(@"%ld", (long)[c alignment]);
    SHOW(@"%ld", (long)[c tag]);
    SHOW(@"%d", [c isFlipped]);
    SHOW(@"%d", [c acceptsFirstResponder]);
    SHOW(@"%d", [c refusesFirstResponder]);
    DO([c setTag:4]);
    SHOW(@"%ld", (long)[c tag]);
    DO([c setStringValue:@"x"]);
    SHOW(@"'%@'", [c stringValue]);
    DO([c setAction:@selector(act:)]);
    SHOW(@"%s", sel_name([c action]));
    DO([c sizeToFit]);
    SHOW(@"%@", NSStringFromRect([c frame]));
    DO([c setEnabled:NO]);
    SHOW(@"%d", [c isEnabled]);

    MyControl *m = [[MyControl alloc] initWithFrame:NSMakeRect(0, 0, 50, 20)];
    SHOW(@"%@", [[m cell] class]);
    SHOW(@"%@", [[[m cell] controlView] class]);
    SHOW(@"%d", [[m cell] isEnabled]);
    DO([m setIntValue:7]);
    SHOW(@"'%@'", [[m cell] stringValue]);
    SHOW(@"%@", obj_desc([m objectValue]));
    DO([m setDoubleValue:2.5]);
    SHOW(@"%d", [m intValue]);
    SHOW(@"%ld", (long)[m integerValue]);
    SHOW(@"%g", [m floatValue]);
    DO([m setTag:12]);
    SHOW(@"%ld", (long)[[m cell] tag]);
    DO([m setAlignment:NSTextAlignmentCenter]);
    SHOW(@"%ld", (long)[[m cell] alignment]);
    DO([m setContinuous:YES]);
    SHOW(@"%d", [[m cell] isContinuous]);
    SHOW(@"%ld", (long)[m sendActionOn:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp]);
    SHOW(@"%ld", (long)[m sendActionOn:NSEventMaskLeftMouseUp]);
    DO([m setControlSize:NSControlSizeMini]);
    SHOW(@"%ld", (long)[[m cell] controlSize]);
    DO([m setLineBreakMode:NSLineBreakByTruncatingMiddle]);
    SHOW(@"%ld", (long)[[m cell] lineBreakMode]);
    DO([m setEnabled:NO]);
    SHOW(@"%d", [[m cell] isEnabled]);
    DO([m setEnabled:YES]);
    DO([m setHighlighted:YES]);
    SHOW(@"%d", [[m cell] isHighlighted]);
    MyCell *other = [[MyCell alloc] initTextCell:@"other"];
    DO([m setCell:other]);
    SHOW(@"%d", [m cell] == other);
    SHOW(@"'%@'", [m stringValue]);
    SHOW(@"%@", [[other controlView] class]);
    SHOW(@"%d", [m selectedCell] == other);
    SHOW(@"%ld", (long)[m selectedTag]);
    SHOW(@"%@", [m currentEditor]);
    DO([m validateEditing]);
    SHOW(@"%d", [m abortEditing]);
    DO([m setAttributedStringValue:[[NSAttributedString alloc] initWithString:@"attributed"]]);
    SHOW(@"'%@'", [m stringValue]);
    SHOW(@"%@", obj_desc([m objectValue]));

    NSControl *from = [[NSControl alloc] initWithFrame:NSZeroRect];
    [from setStringValue:@"3.5"];
    DO([m takeIntValueFrom:from]);
    SHOW(@"%@", obj_desc([m objectValue]));
    DO([m takeDoubleValueFrom:from]);
    SHOW(@"%@", obj_desc([m objectValue]));
    DO([m takeStringValueFrom:from]);
    SHOW(@"%@", obj_desc([m objectValue]));
    DO([m takeObjectValueFrom:from]);
    SHOW(@"%@", obj_desc([m objectValue]));

    out(@"== actions");
    Target *t = [Target new];
    t.name = @"target";
    NSButton *b = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 80, 32)];
    b.target = t;
    b.action = @selector(act:);
    SHOW(@"%d", [b sendAction:@selector(other:) to:t]);
    SHOW(@"%d", [b sendAction:[b action] to:[b target]]);
    SHOW(@"%d", [b sendAction:NULL to:t]);
    SHOW(@"%d", [b sendAction:@selector(act:) to:nil]);
    flush_log(@"sendAction");
    DO([b performClick:nil]);
    flush_log(@"performClick");
    b.enabled = NO;
    DO([b performClick:nil]);
    flush_log(@"performClick disabled");
    b.enabled = YES;
    SHOW(@"%d", [NSApp sendAction:@selector(act:) to:t from:b]);
    flush_log(@"NSApp sendAction");

    /* nil target: the responder chain of the key window */
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 200) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:YES];
    w.releasedWhenClosed = NO;
    Responder *r = [[Responder alloc] initWithFrame:NSMakeRect(0, 0, 50, 50)];
    [w.contentView addSubview:r];
    [w.contentView addSubview:b];
    [w makeFirstResponder:r];
    b.target = nil;
    SHOW(@"%d", [b sendAction:@selector(act:) to:nil]);
    flush_log(@"nil target (window not key)");
    SHOW(@"%@", [[NSApp targetForAction:@selector(act:) to:nil from:b] class]);
    DO([b performClick:nil]);
    flush_log(@"performClick nil target");
    b.target = t;

    out(@"== NSButton");
    NSButton *pb = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 80, 32)];
    dump_control(pb);
    struct {
        NSButtonType type;
        const char *name;
    } types[] = {
        {NSButtonTypeMomentaryLight, "momentaryLight"}, {NSButtonTypePushOnPushOff, "pushOnPushOff"},
        {NSButtonTypeToggle, "toggle"},                 {NSButtonTypeSwitch, "switch"},
        {NSButtonTypeRadio, "radio"},                   {NSButtonTypeMomentaryChange, "momentaryChange"},
        {NSButtonTypeOnOff, "onOff"},                   {NSButtonTypeMomentaryPushIn, "momentaryPushIn"},
        {NSButtonTypeAccelerator, "accelerator"},       {NSButtonTypeMultiLevelAccelerator, "multiLevel"},
    };
    for (size_t i = 0; i < sizeof types / sizeof *types; i++) {
        NSButton *x = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 80, 32)];
        [x setButtonType:types[i].type];
        NSButtonCell *bc = [x cell];
        NSMutableString *cyc = [NSMutableString string];
        for (int k = 0; k < 3; k++) {
            [x performClick:nil];
            [cyc appendFormat:@" %ld", (long)[x state]];
        }
        out(@"type %s: highlightsBy %lx showsStateBy %lx bezel %ld imagePosition %ld alternate %@ image %@ "
            @"bordered %d next %ld cycle%@ mixed %d",
            types[i].name, (long)bc.highlightsBy, (long)bc.showsStateBy, (long)bc.bezelStyle, (long)bc.imagePosition,
            obj_desc(bc.alternateImage), obj_desc(bc.image), bc.isBordered, (long)bc.nextState, cyc,
            bc.allowsMixedState);
    }
    NSButton *mx = [NSButton checkboxWithTitle:@"Mixed" target:t action:@selector(check:)];
    mx.allowsMixedState = YES;
    NSMutableString *cyc = [NSMutableString string];
    for (int k = 0; k < 4; k++) {
        [mx performClick:nil];
        [cyc appendFormat:@" %ld", (long)[mx state]];
    }
    out(@"mixed checkbox cycle%@", cyc);
    flush_log(@"mixed checkbox actions");

    out(@"factories");
    show_width = NO;
    NSButton *f1 = [NSButton buttonWithTitle:@"Push" target:t action:@selector(act:)];
    dump_control(f1);
    out(@"  height %g", f1.frame.size.height);
    NSButton *f2 = [NSButton checkboxWithTitle:@"Check" target:t action:@selector(check:)];
    dump_control(f2);
    out(@"  height %g", f2.frame.size.height);
    NSButton *f3 = [NSButton radioButtonWithTitle:@"Radio" target:t action:@selector(radio:)];
    dump_control(f3);
    out(@"  height %g", f3.frame.size.height);
    NSImage *im = [[NSImage alloc] initWithSize:NSMakeSize(16, 16)];
    NSButton *f4 = [NSButton buttonWithImage:im target:t action:@selector(act:)];
    out(@"buttonWithImage: bezel %ld position %ld bordered %d title '%@' scaling %ld", (long)f4.bezelStyle,
        (long)f4.imagePosition, f4.isBordered, f4.title, (long)f4.imageScaling);
    NSButton *f5 = [NSButton buttonWithTitle:@"Both" image:im target:t action:@selector(act:)];
    out(@"buttonWithTitle:image: bezel %ld position %ld", (long)f5.bezelStyle, (long)f5.imagePosition);

    show_width = YES;
    out(@"titles and images");
    NSButton *tb = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 80, 32)];
    tb.title = @"Title";
    SHOW(@"'%@'", [tb stringValue]);
    SHOW(@"%@", obj_desc([tb objectValue]));
    tb.alternateTitle = @"Alt";
    SHOW(@"'%@'", [[tb attributedAlternateTitle] string]);
    tb.attributedTitle = [[NSAttributedString alloc] initWithString:@"Attr"];
    SHOW(@"'%@'", [tb title]);
    tb.image = im;
    SHOW(@"%ld", (long)[tb imagePosition]);
    tb.imagePosition = NSImageLeft;
    SHOW(@"%ld", (long)[[tb cell] imagePosition]);
    tb.bordered = NO;
    SHOW(@"%d", [[tb cell] isBordered]);
    tb.transparent = YES;
    SHOW(@"%d", [tb isTransparent]);
    tb.keyEquivalent = @"k";
    SHOW(@"%lx", (unsigned long)[tb keyEquivalentModifierMask]);
    tb.bezelStyle = NSBezelStyleSmallSquare;
    SHOW(@"%ld", (long)[[tb cell] bezelStyle]);
    tb.state = NSControlStateValueOn;
    SHOW(@"%@", obj_desc([tb objectValue]));
    SHOW(@"'%@'", [tb stringValue]);
    tb.intValue = 0;
    SHOW(@"%ld", (long)[tb state]);
    tb.stringValue = @"1";
    SHOW(@"%ld", (long)[tb state]);
    SHOW(@"'%@'", [tb title]);
    tb.objectValue = @(-1);
    SHOW(@"%ld", (long)[tb state]);
    tb.allowsMixedState = YES;
    tb.objectValue = @(-1);
    SHOW(@"%ld", (long)[tb state]);
    tb.objectValue = nil;
    SHOW(@"%ld", (long)[tb state]);
    SHOW(@"%d", [tb isFlipped]);

    out(@"radio groups");
    NSView *group = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    NSButton *r1 = [NSButton radioButtonWithTitle:@"One" target:t action:@selector(radio:)];
    NSButton *r2 = [NSButton radioButtonWithTitle:@"Two" target:t action:@selector(radio:)];
    NSButton *r3 = [NSButton radioButtonWithTitle:@"Three" target:t action:@selector(other:)];
    [group addSubview:r1];
    [group addSubview:r2];
    [group addSubview:r3];
    r1.state = NSControlStateValueOn;
    r3.state = NSControlStateValueOn;
    out(@"  states %ld %ld %ld", (long)r1.state, (long)r2.state, (long)r3.state);
    [r2 performClick:nil];
    out(@"  after clicking two: %ld %ld %ld", (long)r1.state, (long)r2.state, (long)r3.state);
    [r2 performClick:nil];
    out(@"  clicking two again: %ld %ld %ld", (long)r1.state, (long)r2.state, (long)r3.state);
    r1.state = NSControlStateValueOn;
    out(@"  setState on one: %ld %ld %ld", (long)r1.state, (long)r2.state, (long)r3.state);
    [r1 performClick:nil];
    out(@"  clicking one: %ld %ld %ld", (long)r1.state, (long)r2.state, (long)r3.state);
    flush_log(@"radio actions");

    out(@"key equivalents");
    NSButton *kb = [NSButton buttonWithTitle:@"Key" target:t action:@selector(act:)];
    kb.keyEquivalent = @"k";
    kb.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSEvent *(^key)(NSString *, NSEventModifierFlags) = ^(NSString *ch, NSEventModifierFlags mods) {
        return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:mods timestamp:0
                            windowNumber:0 context:nil characters:ch charactersIgnoringModifiers:ch isARepeat:NO
                                 keyCode:0];
    };
    SHOW(@"%d", [kb performKeyEquivalent:key(@"k", NSEventModifierFlagCommand)]);
    SHOW(@"%d", [kb performKeyEquivalent:key(@"k", 0)]);
    SHOW(@"%d", [kb performKeyEquivalent:key(@"K", NSEventModifierFlagCommand | NSEventModifierFlagShift)]);
    SHOW(@"%d", [kb performKeyEquivalent:key(@"j", NSEventModifierFlagCommand)]);
    flush_log(@"key equivalents");
    kb.keyEquivalent = @"\r";
    kb.keyEquivalentModifierMask = 0;
    SHOW(@"%d", [kb performKeyEquivalent:key(@"\r", 0)]);
    kb.enabled = NO;
    SHOW(@"%d", [kb performKeyEquivalent:key(@"\r", 0)]);
    flush_log(@"return");

    out(@"== NSTextField");
    NSTextField *plain = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 100, 22)];
    dump_control(plain);
    show_width = NO;
    NSTextField *label = [NSTextField labelWithString:@"Label"];
    dump_control(label);
    out(@"  label frame height %g", label.frame.size.height);
    NSTextField *tf = [NSTextField textFieldWithString:@"Field"];
    dump_control(tf);
    out(@"  text field frame height %g", tf.frame.size.height);
    NSTextField *wrap = [NSTextField wrappingLabelWithString:@"Wrapping"];
    dump_control(wrap);
    NSTextField *alab = [NSTextField labelWithAttributedString:[[NSAttributedString alloc] initWithString:@"Attr"]];
    out(@"labelWithAttributedString: '%@' editable %d selectable %d", alab.stringValue, alab.isEditable,
        alab.isSelectable);
    show_width = YES;
    out(@"text field state");
    tf.editable = NO;
    SHOW(@"%d", [tf isSelectable]);
    tf.selectable = NO;
    SHOW(@"%d", [tf isEditable]);
    tf.editable = YES;
    SHOW(@"%d", [tf isSelectable]);
    tf.bezeled = NO;
    SHOW(@"%d", [tf isBordered]);
    tf.bordered = YES;
    SHOW(@"%d", [tf isBezeled]);
    tf.bezeled = YES;
    SHOW(@"%d", [tf isBordered]);
    tf.bezelStyle = NSTextFieldRoundedBezel;
    SHOW(@"%ld", (long)[[tf cell] bezelStyle]);
    tf.placeholderString = @"Hint";
    SHOW(@"'%@'", [[tf cell] placeholderString]);
    SHOW(@"'%@'", [[tf placeholderAttributedString] string]);
    tf.textColor = NSColor.redColor;
    SHOW(@"%@", color_desc([[tf cell] textColor]));
    tf.drawsBackground = YES;
    SHOW(@"%d", [[tf cell] drawsBackground]);
    tf.integerValue = 12;
    SHOW(@"'%@'", [tf stringValue]);
    SHOW(@"%d", [tf acceptsFirstResponder]);
    tf.enabled = NO;
    SHOW(@"%d", [tf acceptsFirstResponder]);
    tf.enabled = YES;
    tf.maximumNumberOfLines = 3;
    SHOW(@"%ld", (long)[tf maximumNumberOfLines]);
    SHOW(@"%d", [tf allowsDefaultTighteningForTruncation]);
    SHOW(@"%d", [tf isFlipped]);
    SHOW(@"%@", [NSTextField cellClass]);
    SHOW(@"%@", [NSSecureTextField cellClass]);
    NSSecureTextField *sec = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 100, 22)];
    dump_control(sec);
    sec.stringValue = @"hunter2";
    SHOW(@"'%@'", [sec stringValue]);

    out(@"== NSSlider");
    NSSlider *sl = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 200, 28)];
    dump_control(sl);
    sl.maxValue = 10;
    sl.doubleValue = 15;
    SHOW(@"%g", [sl doubleValue]);
    sl.doubleValue = -3;
    SHOW(@"%g", [sl doubleValue]);
    sl.minValue = 2;
    SHOW(@"%g", [sl doubleValue]);
    sl.doubleValue = 4.4;
    sl.numberOfTickMarks = 5;
    SHOW(@"%g", [sl tickMarkValueAtIndex:0]);
    SHOW(@"%g", [sl tickMarkValueAtIndex:4]);
    SHOW(@"%g", [sl tickMarkValueAtIndex:7]);
    SHOW(@"%g", [sl closestTickMarkValueToValue:5.1]);
    SHOW(@"%g", [sl doubleValue]);
    sl.allowsTickMarkValuesOnly = YES;
    SHOW(@"%g", [sl doubleValue]);
    sl.doubleValue = 7.1;
    SHOW(@"%g", [sl doubleValue]);
    SHOW(@"'%@'", [sl stringValue]);
    SHOW(@"%d", [sl isVertical]);
    NSSlider *vs = [[NSSlider alloc] initWithFrame:NSMakeRect(0, 0, 24, 200)];
    SHOW(@"%d", [vs isVertical]);
    show_width = NO;
    NSSlider *fs = [NSSlider sliderWithValue:3 minValue:1 maxValue:9 target:t action:@selector(slide:)];
    dump_control(fs);
    show_width = YES;
    NSSlider *ls = [NSSlider sliderWithTarget:t action:@selector(slide:)];
    out(@"sliderWithTarget: %g %g %g", ls.minValue, ls.maxValue, ls.doubleValue);
    SHOW(@"%@", [NSSlider cellClass]);

    out(@"== NSProgressIndicator");
    NSProgressIndicator *pi = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
    dump_control(pi);
    pi.indeterminate = NO;
    pi.doubleValue = 150;
    SHOW(@"%g", [pi doubleValue]);
    pi.doubleValue = 40;
    [pi incrementBy:15];
    SHOW(@"%g", [pi doubleValue]);
    pi.minValue = 50;
    SHOW(@"%g", [pi doubleValue]);
    pi.style = NSProgressIndicatorStyleSpinning;
    SHOW(@"%d", [pi isDisplayedWhenStopped]);
    SHOW(@"%d", [pi isIndeterminate]);
    [pi sizeToFit];
    out(@"  spinning sizeToFit %@", NSStringFromSize(pi.frame.size));
    pi.controlSize = NSControlSizeSmall;
    [pi sizeToFit];
    out(@"  small spinning sizeToFit %@", NSStringFromSize(pi.frame.size));
    NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 200, 20)];
    bar.indeterminate = NO;
    [bar startAnimation:nil];
    [bar stopAnimation:nil];
    SHOW(@"%d", [bar isIndeterminate]);

    out(@"== NSStepper");
    NSStepper *st = [[NSStepper alloc] initWithFrame:NSMakeRect(0, 0, 19, 28)];
    dump_control(st);
    st.maxValue = 10;
    st.doubleValue = 12;
    SHOW(@"%g", [st doubleValue]);
    st.doubleValue = -1;
    SHOW(@"%g", [st doubleValue]);
    st.increment = 3;
    st.doubleValue = 9;
    SHOW(@"%g", [st doubleValue]);
    SHOW(@"%@", [NSStepper cellClass]);

    out(@"== NSSegmentedControl");
    NSSegmentedControl *sg = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    dump_control(sg);
    sg.segmentCount = 3;
    [sg setLabel:@"A" forSegment:0];
    [sg setLabel:@"B" forSegment:1];
    [sg setLabel:@"C" forSegment:2];
    [sg setTag:5 forSegment:2];
    [sg setWidth:40 forSegment:1];
    SHOW(@"%ld", (long)[sg selectedSegment]);
    sg.selectedSegment = 1;
    SHOW(@"%ld", (long)[sg selectedSegment]);
    [sg setSelected:YES forSegment:2];
    SHOW(@"%ld", (long)[sg selectedSegment]);
    SHOW(@"%d", [sg isSelectedForSegment:1]);
    SHOW(@"%d", [sg selectSegmentWithTag:5]);
    SHOW(@"%d", [sg selectSegmentWithTag:99]);
    SHOW(@"%ld", (long)[sg selectedSegment]);
    sg.trackingMode = NSSegmentSwitchTrackingSelectAny;
    [sg setSelected:YES forSegment:0];
    SHOW(@"%ld", (long)[sg selectedSegment]);
    SHOW(@"%d", [sg isSelectedForSegment:2]);
    [sg setSelected:NO forSegment:0];
    SHOW(@"%ld", (long)[sg selectedSegment]);
    sg.segmentCount = 2;
    SHOW(@"%ld", (long)[sg selectedSegment]);
    SHOW(@"'%@'", [sg labelForSegment:1]);
    SHOW(@"%g", [sg widthForSegment:1]);
    sg.segmentCount = 4;
    SHOW(@"'%@'", [sg labelForSegment:3]);
    SHOW(@"%d", [sg isEnabledForSegment:3]);
    [sg setEnabled:NO forSegment:3];
    SHOW(@"%d", [sg isEnabledForSegment:3]);
    SHOW(@"'%@'", [sg labelForSegment:9]);
    DO([sg setLabel:@"x" forSegment:9]);
    NSSegmentedControl *fsg = [NSSegmentedControl segmentedControlWithLabels:@[ @"X", @"Y" ]
                                                                trackingMode:NSSegmentSwitchTrackingMomentary
                                                                      target:t action:@selector(segment:)];
    show_width = NO;
    dump_control(fsg);
    show_width = YES;
    SHOW(@"%@", [NSSegmentedControl cellClass]);

    out(@"== NSColorWell");
    NSColorWell *cw = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 24)];
    dump_control(cw);
    cw.color = NSColor.greenColor;
    SHOW(@"%@", color_desc([cw color]));
    SHOW(@"%ld", (long)[cw colorWellStyle]);

    out(@"== NSImageView");
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 48, 48)];
    dump_control(iv);
    iv.image = im;
    SHOW(@"%@", obj_desc([iv objectValue]));
    SHOW(@"%@", obj_desc([[iv cell] objectValue]));
    NSImageView *fiv = [NSImageView imageViewWithImage:im];
    show_width = NO;
    dump_control(fiv);
    show_width = YES;

    out(@"== NSBox");
    NSBox *bx = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    dump_control(bx);
    bx.boxType = NSBoxCustom;
    SHOW(@"%g", [bx borderWidth]);
    SHOW(@"%@", color_desc([bx fillColor]));
    bx.title = @"Changed";
    SHOW(@"'%@'", [[bx titleCell] stringValue]);
    NSView *inner = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    bx.contentView = inner;
    SHOW(@"%d", [inner superview] == bx);
    SHOW(@"%lu", (unsigned long)[[bx subviews] count]);

    out(@"== NSLevelIndicator");
    NSLevelIndicator *li = [[NSLevelIndicator alloc] initWithFrame:NSMakeRect(0, 0, 100, 18)];
    dump_control(li);
    li.maxValue = 5;
    li.doubleValue = 7;
    SHOW(@"%g", [li doubleValue]);
    li.doubleValue = -1;
    SHOW(@"%g", [li doubleValue]);
}

#pragma mark - The nib

static void
test_nib(NSString *path)
{
    out(@"== nib");
    NSNib *nib = [[NSNib alloc] initWithNibData:[NSData dataWithContentsOfFile:path] bundle:nil];
    Owner *owner = [Owner new];
    owner.name = @"owner";
    NSArray *top = nil;
    out(@"instantiated %d", [nib instantiateWithOwner:owner topLevelObjects:&top]);
    NSWindow *w = owner.window;
    out(@"window %@ field %@ ok %@", [w class], [owner.field class], [owner.ok class]);
    for (NSView *v in [w.contentView subviews])
        dump_control(v);

    out(@"nib behaviour");
    NSArray *views = [w.contentView subviews];
    NSButton *ok = owner.ok, *cancel = views[1], *check = views[2], *mixed = views[3], *ra = views[4], *rb = views[5];
    NSButton *toggle = views[6];
    [ok performClick:nil];
    [check performClick:nil];
    out(@"  check state %ld", (long)check.state);
    [mixed performClick:nil];
    out(@"  mixed state %ld", (long)mixed.state);
    [mixed performClick:nil];
    out(@"  mixed state %ld", (long)mixed.state);
    [rb performClick:nil];
    out(@"  radios %ld %ld", (long)ra.state, (long)rb.state);
    [toggle performClick:nil];
    out(@"  toggle state %ld title '%@'", (long)toggle.state, toggle.title);
    [cancel performClick:nil];
    flush_log(@"clicks");
    NSEvent *ret = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                                windowNumber:0 context:nil characters:@"\r" charactersIgnoringModifiers:@"\r"
                                   isARepeat:NO keyCode:36];
    out(@"  ok performKeyEquivalent %d", [ok performKeyEquivalent:ret]);
    out(@"  window performKeyEquivalent %d", [w performKeyEquivalent:ret]);
    out(@"  default button cell is ok's %d", [w defaultButtonCell] == [ok cell]);
    flush_log(@"return");
    NSSlider *slider = views[13];
    slider.doubleValue = 13;
    out(@"  slider snapped %g", slider.doubleValue);
    NSStepper *stepper = views[17];
    out(@"  stepper %g", stepper.doubleValue);
    NSSegmentedControl *seg = views[18];
    seg.selectedSegment = 0;
    out(@"  segment %ld", (long)seg.selectedSegment);
    [seg performClick:nil];
    flush_log(@"segment click");
}

int
main(int argc, char **argv)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        printf("%s\n", class_getImageName([NSButton class]));
        [NSApplication sharedApplication];
        log_ = [NSMutableArray array];
        test_cells();
        test_controls();
        test_nib(argc > 1 ? @(argv[1]) : @"/usr/local/share/finch/controls-test.nib");
    }
    return 0;
}
