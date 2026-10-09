/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* NSLevelIndicator: an NSControl over an NSLevelIndicatorCell, and its colours. */
#import "NSControl_Finch.h"

@implementation NSLevelIndicator {
    NSColor *_fillColor, *_warningFillColor, *_criticalFillColor;
    NSImage *_ratingImage, *_ratingPlaceholderImage;
    NSLevelIndicatorPlaceholderVisibility _placeholderVisibility;
    BOOL _tiered;
}

+ (Class)cellClass
{
    return [super cellClass] ?: [NSLevelIndicatorCell class];
}

- (void)dealloc
{
    [_fillColor release];
    [_warningFillColor release];
    [_criticalFillColor release];
    [_ratingImage release];
    [_ratingPlaceholderImage release];
    [super dealloc];
}

static NSLevelIndicatorCell *
cell_of(NSLevelIndicator *l)
{
    id c = [l cell];
    return [c isKindOfClass:[NSLevelIndicatorCell class]] ? c : nil;
}

- (NSLevelIndicatorStyle)levelIndicatorStyle { return [cell_of(self) levelIndicatorStyle]; }
- (void)setLevelIndicatorStyle:(NSLevelIndicatorStyle)s { [cell_of(self) setLevelIndicatorStyle:s]; }
- (BOOL)isEditable { return [[self cell] isEditable]; }
- (void)setEditable:(BOOL)flag { [[self cell] setEditable:flag]; }
- (double)minValue { return [cell_of(self) minValue]; }
- (void)setMinValue:(double)v { [cell_of(self) setMinValue:v]; }
- (double)maxValue { return [cell_of(self) maxValue]; }
- (void)setMaxValue:(double)v { [cell_of(self) setMaxValue:v]; }
- (double)warningValue { return [cell_of(self) warningValue]; }
- (void)setWarningValue:(double)v { [cell_of(self) setWarningValue:v]; }
- (double)criticalValue { return [cell_of(self) criticalValue]; }
- (void)setCriticalValue:(double)v { [cell_of(self) setCriticalValue:v]; }
- (NSTickMarkPosition)tickMarkPosition { return [cell_of(self) tickMarkPosition]; }
- (void)setTickMarkPosition:(NSTickMarkPosition)p { [cell_of(self) setTickMarkPosition:p]; }
- (NSInteger)numberOfTickMarks { return [cell_of(self) numberOfTickMarks]; }
- (void)setNumberOfTickMarks:(NSInteger)n { [cell_of(self) setNumberOfTickMarks:n]; }
- (NSInteger)numberOfMajorTickMarks { return [cell_of(self) numberOfMajorTickMarks]; }
- (void)setNumberOfMajorTickMarks:(NSInteger)n { [cell_of(self) setNumberOfMajorTickMarks:n]; }
- (double)tickMarkValueAtIndex:(NSInteger)index { return [cell_of(self) tickMarkValueAtIndex:index]; }
- (NSRect)rectOfTickMarkAtIndex:(NSInteger)index { return [cell_of(self) rectOfTickMarkAtIndex:index]; }

#define COLOR_PROPERTY(get, set, ivar, fallback)                                                                       \
    -(NSColor *)get { return ivar ?: [NSColor fallback]; }                                                                                   \
    -(void)set:(NSColor *)c                                                                                            \
    {                                                                                                                  \
        [ivar release];                                                                                                \
        ivar = [c copy];                                                                                               \
        [self setNeedsDisplay:YES];                                                                                    \
    }

COLOR_PROPERTY(fillColor, setFillColor, _fillColor, systemGreenColor)
COLOR_PROPERTY(warningFillColor, setWarningFillColor, _warningFillColor, systemYellowColor)
COLOR_PROPERTY(criticalFillColor, setCriticalFillColor, _criticalFillColor, systemRedColor)

- (BOOL)drawsTieredCapacityLevels { return _tiered; }
- (void)setDrawsTieredCapacityLevels:(BOOL)flag { _tiered = flag; }
- (NSLevelIndicatorPlaceholderVisibility)placeholderVisibility { return _placeholderVisibility; }
- (void)setPlaceholderVisibility:(NSLevelIndicatorPlaceholderVisibility)v { _placeholderVisibility = v; }
- (NSImage *)ratingImage { return _ratingImage; }

- (void)setRatingImage:(NSImage *)image
{
    [_ratingImage release];
    _ratingImage = [image retain];
}

- (NSImage *)ratingPlaceholderImage { return _ratingPlaceholderImage; }

- (void)setRatingPlaceholderImage:(NSImage *)image
{
    [_ratingPlaceholderImage release];
    _ratingPlaceholderImage = [image retain];
}

- (NSSize)intrinsicContentSize
{
    NSLevelIndicatorCell *c = cell_of(self);
    NSSize s = [c cellSize];
    if ([c levelIndicatorStyle] == NSLevelIndicatorStyleRating)
        return s;
    return NSMakeSize(NSViewNoIntrinsicMetric, s.height);
}

- (BOOL)_finchBecomesFirstResponderOnClick { return [self isEditable]; }

@end
