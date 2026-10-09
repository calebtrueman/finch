/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Accessibility.framework's Objective-C half (Accessibility.h), Finch's:
 *   - audio graph and chart descriptors (AXChartDescriptor and its axes, series and
 *     points), which apps give assistive technologies to describe charts;
 *   - custom content, math expressions, the current request;
 *   - braille maps, and a braille translator with Finch's own uncontracted (grade 1)
 *     English table, in Unicode braille patterns;
 *   - the accessibility settings, read from the com.apple.Accessibility defaults domain
 *     (Finch has no Accessibility pane yet, so they keep macOS's defaults);
 *   - colour names for colours (AXNameFromColor).
 * Finch has no assistive technologies yet: the live audio graph makes no sound and there
 * is no current request.
 */
#import <Accessibility/Accessibility.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>

#pragma mark - Settings

NSNotificationName const AXPrefersHorizontalTextLayoutDidChangeNotification = @"com.apple.accessibility.prefers.horizontal.text";
NSNotificationName const AXAnimatedImagesEnabledDidChangeNotification =
    @"com.apple.accessibility.reduce.motion.autoplay.animated.images.status";
NSNotificationName const AXPrefersNonBlinkingTextInsertionIndicatorDidChangeNotification =
    @"com.apple.accessibility.non.blinking.cursor.status";
NSNotificationName const AXPrefersActionSliderAlternativeDidChangeNotification =
    @"com.apple.accessibility.prefer.action.slider.alternative.status";
NSNotificationName const AXShowBordersEnabledStatusDidChangeNotification = @"NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification";
NSNotificationName const AXReduceHighlightingEffectsEnabledDidChangeNotification =
    @"com.apple.accessibility.reduce.highlighting.effects.status";

static BOOL
setting(NSString *key, BOOL fallback)
{
    NSUserDefaults *d = [[[NSUserDefaults alloc] initWithSuiteName:@"com.apple.Accessibility"] autorelease];
    id v = [d objectForKey:key];
    return v ? [v boolValue] : fallback;
}

BOOL AXPrefersHorizontalTextLayout(void) { return setting(@"PrefersHorizontalTextLayout", NO); }
BOOL AXAnimatedImagesEnabled(void) { return setting(@"AnimatedImagesEnabled", YES); }
BOOL AXAssistiveAccessEnabled(void) { return NO; }
BOOL AXPrefersNonBlinkingTextInsertionIndicator(void) { return setting(@"PrefersNonBlinkingTextInsertionIndicator", NO); }
BOOL AXPrefersActionSliderAlternative(void) { return setting(@"PrefersActionSliderAlternative", NO); }
BOOL AXShowBordersEnabled(void) { return setting(@"ShowBordersEnabled", NO); }
BOOL AXReduceHighlightingEffectsEnabled(void) { return setting(@"ReduceHighlightingEffectsEnabled", NO); }

/* There is no Settings pane to open these features in yet. */
void
AXOpenSettingsFeature(AXSettingsFeature feature, void (^completionHandler)(NSError *error))
{
    if (completionHandler)
        completionHandler([NSError errorWithDomain:NSCocoaErrorDomain code:NSFeatureUnsupportedError userInfo:nil]);
}

Boolean
AXOpenSettingsFeatureIsSupported(AXSettingsFeature feature)
{
    return false;
}

#pragma mark - Technologies and requests

AXTechnology AXTechnologyVoiceOver = @"VoiceOver";
AXTechnology AXTechnologySwitchControl = @"SwitchControl";
AXTechnology AXTechnologyVoiceControl = @"VoiceControl";
AXTechnology AXTechnologyFullKeyboardAccess = @"FullKeyboardAccess";
AXTechnology AXTechnologySpeakScreen = @"SpeakScreen";
AXTechnology AXTechnologyAutomation = @"Automation";
AXTechnology AXTechnologyHoverText = @"HoverText";
AXTechnology AXTechnologyZoom = @"Zoom";

@implementation AXRequest {
    NSString *_technology;
}

+ (BOOL)supportsSecureCoding { return YES; }
+ (AXRequest *)currentRequest { return nil; }
- (AXTechnology)technology { return _technology; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_technology forKey:@"technology"]; }

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init]))
        _technology = [[coder decodeObjectOfClass:[NSString class] forKey:@"technology"] copy];
    return self;
}

- (void)dealloc
{
    [_technology release];
    [super dealloc];
}

@end

#pragma mark - Charts

static NSAttributedString *
attributed(NSString *s)
{
    return [[[NSAttributedString alloc] initWithString:s ?: @""] autorelease];
}

@implementation AXNumericDataAxisDescriptor {
    NSAttributedString *_attributedTitle;
}
@synthesize scaleType = _scaleType, lowerBound = _lowerBound, upperBound = _upperBound,
            valueDescriptionProvider = _valueDescriptionProvider, gridlinePositions = _gridlinePositions;

- (instancetype)initWithAttributedTitle:(NSAttributedString *)title lowerBound:(double)lower upperBound:(double)upper
                      gridlinePositions:(NSArray<NSNumber *> *)gridlines
               valueDescriptionProvider:(NSString * (^)(double))provider
{
    if ((self = [super init])) {
        _attributedTitle = [title copy];
        _lowerBound = lower;
        _upperBound = upper;
        _gridlinePositions = [gridlines copy];
        _valueDescriptionProvider = [provider copy];
    }
    return self;
}

- (instancetype)initWithTitle:(NSString *)title lowerBound:(double)lower upperBound:(double)upper
            gridlinePositions:(NSArray<NSNumber *> *)gridlines valueDescriptionProvider:(NSString * (^)(double))provider
{
    return [self initWithAttributedTitle:attributed(title) lowerBound:lower upperBound:upper gridlinePositions:gridlines
                valueDescriptionProvider:provider];
}

- (void)dealloc
{
    [_attributedTitle release];
    [_gridlinePositions release];
    [_valueDescriptionProvider release];
    [super dealloc];
}

- (NSString *)title { return [_attributedTitle string]; }
- (void)setTitle:(NSString *)title { [self setAttributedTitle:attributed(title)]; }
- (NSAttributedString *)attributedTitle { return _attributedTitle; }
- (void)setAttributedTitle:(NSAttributedString *)t
{
    [_attributedTitle autorelease];
    _attributedTitle = [t copy];
}

- (id)copyWithZone:(NSZone *)zone
{
    AXNumericDataAxisDescriptor *c = [[AXNumericDataAxisDescriptor allocWithZone:zone]
        initWithAttributedTitle:_attributedTitle lowerBound:_lowerBound upperBound:_upperBound
              gridlinePositions:_gridlinePositions valueDescriptionProvider:_valueDescriptionProvider];
    c.scaleType = _scaleType;
    return c;
}

@end

@implementation AXCategoricalDataAxisDescriptor {
    NSAttributedString *_attributedTitle;
}
@synthesize categoryOrder = _categoryOrder;

- (instancetype)initWithAttributedTitle:(NSAttributedString *)title categoryOrder:(NSArray<NSString *> *)order
{
    if ((self = [super init])) {
        _attributedTitle = [title copy];
        _categoryOrder = [order copy];
    }
    return self;
}

- (instancetype)initWithTitle:(NSString *)title categoryOrder:(NSArray<NSString *> *)order
{
    return [self initWithAttributedTitle:attributed(title) categoryOrder:order];
}

- (void)dealloc
{
    [_attributedTitle release];
    [_categoryOrder release];
    [super dealloc];
}

- (NSString *)title { return [_attributedTitle string]; }
- (void)setTitle:(NSString *)title { [self setAttributedTitle:attributed(title)]; }
- (NSAttributedString *)attributedTitle { return _attributedTitle; }
- (void)setAttributedTitle:(NSAttributedString *)t
{
    [_attributedTitle autorelease];
    _attributedTitle = [t copy];
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[AXCategoricalDataAxisDescriptor allocWithZone:zone] initWithAttributedTitle:_attributedTitle categoryOrder:_categoryOrder];
}

@end

@implementation AXDataPointValue
@synthesize number = _number, category = _category;

+ (instancetype)valueWithNumber:(double)number
{
    AXDataPointValue *v = [[[self alloc] _finchInit] autorelease];
    v->_number = number;
    return v;
}

+ (instancetype)valueWithCategory:(NSString *)category
{
    AXDataPointValue *v = [[[self alloc] _finchInit] autorelease];
    v->_category = [category copy];
    return v;
}

- (instancetype)_finchInit { return [super init]; }

- (void)dealloc
{
    [_category release];
    [super dealloc];
}

- (id)copyWithZone:(NSZone *)zone
{
    AXDataPointValue *v = [[AXDataPointValue allocWithZone:zone] _finchInit];
    v->_number = _number;
    v->_category = [_category copy];
    return v;
}

@end

@implementation AXDataPoint {
    NSAttributedString *_attributedLabel;
}
@synthesize xValue = _xValue, yValue = _yValue, additionalValues = _additionalValues;

- (instancetype)initWithX:(AXDataPointValue *)x y:(AXDataPointValue *)y additionalValues:(NSArray<AXDataPointValue *> *)more
                    label:(NSString *)label
{
    if ((self = [super init])) {
        _xValue = [x copy];
        _yValue = [y copy];
        _additionalValues = [more copy] ?: [NSArray new];
        _attributedLabel = label ? [attributed(label) retain] : nil;
    }
    return self;
}

- (instancetype)initWithX:(AXDataPointValue *)x y:(AXDataPointValue *)y additionalValues:(NSArray<AXDataPointValue *> *)more
{
    return [self initWithX:x y:y additionalValues:more label:nil];
}

- (instancetype)initWithX:(AXDataPointValue *)x y:(AXDataPointValue *)y
{
    return [self initWithX:x y:y additionalValues:nil label:nil];
}

- (void)dealloc
{
    [_xValue release];
    [_yValue release];
    [_additionalValues release];
    [_attributedLabel release];
    [super dealloc];
}

- (NSString *)label { return [_attributedLabel string]; }
- (void)setLabel:(NSString *)label { [self setAttributedLabel:label ? attributed(label) : nil]; }
- (NSAttributedString *)attributedLabel { return _attributedLabel; }
- (void)setAttributedLabel:(NSAttributedString *)l
{
    [_attributedLabel autorelease];
    _attributedLabel = [l copy];
}

- (id)copyWithZone:(NSZone *)zone
{
    AXDataPoint *p = [[AXDataPoint allocWithZone:zone] initWithX:_xValue y:_yValue additionalValues:_additionalValues label:nil];
    p.attributedLabel = _attributedLabel;
    return p;
}

@end

@implementation AXDataSeriesDescriptor {
    NSAttributedString *_attributedName;
}
@synthesize isContinuous = _isContinuous, dataPoints = _dataPoints;

- (instancetype)initWithAttributedName:(NSAttributedString *)name isContinuous:(BOOL)continuous dataPoints:(NSArray<AXDataPoint *> *)points
{
    if ((self = [super init])) {
        _attributedName = [name copy];
        _isContinuous = continuous;
        _dataPoints = [points copy];
    }
    return self;
}

- (instancetype)initWithName:(NSString *)name isContinuous:(BOOL)continuous dataPoints:(NSArray<AXDataPoint *> *)points
{
    return [self initWithAttributedName:attributed(name) isContinuous:continuous dataPoints:points];
}

- (void)dealloc
{
    [_attributedName release];
    [_dataPoints release];
    [super dealloc];
}

- (NSString *)name { return [_attributedName string]; }
- (void)setName:(NSString *)name { [self setAttributedName:attributed(name)]; }
- (NSAttributedString *)attributedName { return _attributedName; }
- (void)setAttributedName:(NSAttributedString *)n
{
    [_attributedName autorelease];
    _attributedName = [n copy];
}

- (id)copyWithZone:(NSZone *)zone
{
    return [[AXDataSeriesDescriptor allocWithZone:zone] initWithAttributedName:_attributedName isContinuous:_isContinuous
                                                                     dataPoints:_dataPoints];
}

@end

@implementation AXChartDescriptor {
    NSAttributedString *_attributedTitle;
}
@synthesize summary = _summary, contentDirection = _contentDirection, contentFrame = _contentFrame, series = _series,
            xAxis = _xAxis, yAxis = _yAxis, additionalAxes = _additionalAxes;

- (instancetype)initWithAttributedTitle:(NSAttributedString *)title summary:(NSString *)summary
                        xAxisDescriptor:(id<AXDataAxisDescriptor>)xAxis yAxisDescriptor:(AXNumericDataAxisDescriptor *)yAxis
                         additionalAxes:(NSArray<id<AXDataAxisDescriptor>> *)more series:(NSArray<AXDataSeriesDescriptor *> *)series
{
    if ((self = [super init])) {
        _attributedTitle = [title copy];
        _summary = [summary copy];
        _xAxis = [(id)xAxis retain];
        _yAxis = [yAxis retain];
        _additionalAxes = [more copy];
        _series = [series copy];
    }
    return self;
}

- (instancetype)initWithTitle:(NSString *)title summary:(NSString *)summary xAxisDescriptor:(id<AXDataAxisDescriptor>)xAxis
              yAxisDescriptor:(AXNumericDataAxisDescriptor *)yAxis additionalAxes:(NSArray<id<AXDataAxisDescriptor>> *)more
                       series:(NSArray<AXDataSeriesDescriptor *> *)series
{
    return [self initWithAttributedTitle:title ? attributed(title) : nil summary:summary xAxisDescriptor:xAxis yAxisDescriptor:yAxis
                          additionalAxes:more series:series];
}

- (instancetype)initWithTitle:(NSString *)title summary:(NSString *)summary xAxisDescriptor:(id<AXDataAxisDescriptor>)xAxis
              yAxisDescriptor:(AXNumericDataAxisDescriptor *)yAxis series:(NSArray<AXDataSeriesDescriptor *> *)series
{
    return [self initWithTitle:title summary:summary xAxisDescriptor:xAxis yAxisDescriptor:yAxis additionalAxes:nil series:series];
}

- (instancetype)initWithAttributedTitle:(NSAttributedString *)title summary:(NSString *)summary
                        xAxisDescriptor:(id<AXDataAxisDescriptor>)xAxis yAxisDescriptor:(AXNumericDataAxisDescriptor *)yAxis
                                 series:(NSArray<AXDataSeriesDescriptor *> *)series
{
    return [self initWithAttributedTitle:title summary:summary xAxisDescriptor:xAxis yAxisDescriptor:yAxis additionalAxes:nil
                                  series:series];
}

- (void)dealloc
{
    [_attributedTitle release];
    [_summary release];
    [(id)_xAxis release];
    [_yAxis release];
    [_additionalAxes release];
    [_series release];
    [super dealloc];
}

- (NSString *)title { return [_attributedTitle string]; }
- (void)setTitle:(NSString *)title { [self setAttributedTitle:title ? attributed(title) : nil]; }
- (NSAttributedString *)attributedTitle { return _attributedTitle; }
- (void)setAttributedTitle:(NSAttributedString *)t
{
    [_attributedTitle autorelease];
    _attributedTitle = [t copy];
}

- (id)copyWithZone:(NSZone *)zone
{
    AXChartDescriptor *c = [[AXChartDescriptor allocWithZone:zone] initWithAttributedTitle:_attributedTitle summary:_summary
                                                                          xAxisDescriptor:_xAxis yAxisDescriptor:_yAxis
                                                                           additionalAxes:_additionalAxes series:_series];
    c.contentDirection = _contentDirection;
    c.contentFrame = _contentFrame;
    return c;
}

@end

@implementation AXLiveAudioGraph
+ (void)start {}
+ (void)updateValue:(double)value {}
+ (void)stop {}
@end

#pragma mark - Custom content

@implementation AXCustomContent {
    NSAttributedString *_label, *_value;
}
@synthesize importance = _importance;

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)customContentWithAttributedLabel:(NSAttributedString *)label attributedValue:(NSAttributedString *)value
{
    AXCustomContent *c = [[[self alloc] _finchInit] autorelease];
    c->_label = [label copy];
    c->_value = [value copy];
    return c;
}

+ (instancetype)customContentWithLabel:(NSString *)label value:(NSString *)value
{
    return [self customContentWithAttributedLabel:attributed(label) attributedValue:attributed(value)];
}

- (instancetype)_finchInit { return [super init]; }

- (void)dealloc
{
    [_label release];
    [_value release];
    [super dealloc];
}

- (NSString *)label { return [_label string]; }
- (NSAttributedString *)attributedLabel { return _label; }
- (NSString *)value { return [_value string]; }
- (NSAttributedString *)attributedValue { return _value; }

- (id)copyWithZone:(NSZone *)zone
{
    AXCustomContent *c = [[AXCustomContent allocWithZone:zone] _finchInit];
    c->_label = [_label copy];
    c->_value = [_value copy];
    c->_importance = _importance;
    return c;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_label forKey:@"label"];
    [coder encodeObject:_value forKey:@"value"];
    [coder encodeInteger:(NSInteger)_importance forKey:@"importance"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [super init])) {
        _label = [[coder decodeObjectOfClass:[NSAttributedString class] forKey:@"label"] copy] ?: [attributed(@"") retain];
        _value = [[coder decodeObjectOfClass:[NSAttributedString class] forKey:@"value"] copy] ?: [attributed(@"") retain];
        _importance = (AXCustomContentImportance)[coder decodeIntegerForKey:@"importance"];
    }
    return self;
}

@end

#pragma mark - Math expressions

@implementation AXMathExpression
@end

#define CONTENT_EXPRESSION(cls)                                      \
    @implementation cls {                                            \
        NSString *_content;                                          \
    }                                                                \
    -(instancetype)initWithContent : (NSString *)content             \
    {                                                                \
        if ((self = [super init]))                                   \
            _content = [content copy];                               \
        return self;                                                 \
    }                                                                \
    -(void)dealloc                                                   \
    {                                                                \
        [_content release];                                          \
        [super dealloc];                                             \
    }                                                                \
    -(NSString *)content { return _content; }                        \
    @end

CONTENT_EXPRESSION(AXMathExpressionNumber)
CONTENT_EXPRESSION(AXMathExpressionIdentifier)
CONTENT_EXPRESSION(AXMathExpressionOperator)
CONTENT_EXPRESSION(AXMathExpressionText)

#define LIST_EXPRESSION(cls)                                                    \
    @implementation cls {                                                       \
        NSArray *_expressions;                                                  \
    }                                                                           \
    -(instancetype)initWithExpressions : (NSArray<AXMathExpression *> *)list    \
    {                                                                           \
        if ((self = [super init]))                                              \
            _expressions = [list copy];                                         \
        return self;                                                            \
    }                                                                           \
    -(void)dealloc                                                              \
    {                                                                           \
        [_expressions release];                                                 \
        [super dealloc];                                                        \
    }                                                                           \
    -(NSArray<AXMathExpression *> *)expressions { return _expressions; }        \
    @end

LIST_EXPRESSION(AXMathExpressionRow)
LIST_EXPRESSION(AXMathExpressionTable)
LIST_EXPRESSION(AXMathExpressionTableRow)
LIST_EXPRESSION(AXMathExpressionTableCell)

@implementation AXMathExpressionFenced {
    NSArray *_expressions;
    NSString *_open, *_close;
}
- (instancetype)initWithExpressions:(NSArray<AXMathExpression *> *)list openString:(NSString *)open closeString:(NSString *)close
{
    if ((self = [super init])) {
        _expressions = [list copy];
        _open = [open copy];
        _close = [close copy];
    }
    return self;
}
- (void)dealloc
{
    [_expressions release];
    [_open release];
    [_close release];
    [super dealloc];
}
- (NSArray<AXMathExpression *> *)expressions { return _expressions; }
- (NSString *)openString { return _open; }
- (NSString *)closeString { return _close; }
@end

@implementation AXMathExpressionUnderOver {
    AXMathExpression *_base, *_under, *_over;
}
- (instancetype)initWithBaseExpression:(AXMathExpression *)base underExpression:(AXMathExpression *)under
                        overExpression:(AXMathExpression *)over
{
    if ((self = [super init])) {
        _base = [base retain];
        _under = [under retain];
        _over = [over retain];
    }
    return self;
}
- (void)dealloc
{
    [_base release];
    [_under release];
    [_over release];
    [super dealloc];
}
- (AXMathExpression *)baseExpression { return _base; }
- (AXMathExpression *)underExpression { return _under; }
- (AXMathExpression *)overExpression { return _over; }
@end

/* The header types the base as an array in the initializer and an expression in the
 * property; an array base is kept as a row. */
@implementation AXMathExpressionSubSuperscript {
    AXMathExpression *_base;
    NSArray *_sub, *_super;
}
- (instancetype)initWithBaseExpression:(NSArray<AXMathExpression *> *)base subscriptExpressions:(NSArray<AXMathExpression *> *)sub
                superscriptExpressions:(NSArray<AXMathExpression *> *)sup
{
    if ((self = [super init])) {
        id b = base;
        _base = [b isKindOfClass:[NSArray class]] ? [[AXMathExpressionRow alloc] initWithExpressions:b] : [b retain];
        _sub = [sub copy];
        _super = [sup copy];
    }
    return self;
}
- (void)dealloc
{
    [_base release];
    [_sub release];
    [_super release];
    [super dealloc];
}
- (AXMathExpression *)baseExpression { return _base; }
- (NSArray<AXMathExpression *> *)subscriptExpressions { return _sub; }
- (NSArray<AXMathExpression *> *)superscriptExpressions { return _super; }
@end

@implementation AXMathExpressionFraction {
    AXMathExpression *_numerator, *_denominator;
}
- (instancetype)initWithNumeratorExpression:(AXMathExpression *)numerator denimonatorExpression:(AXMathExpression *)denominator
{
    if ((self = [super init])) {
        _numerator = [numerator retain];
        _denominator = [denominator retain];
    }
    return self;
}
- (void)dealloc
{
    [_numerator release];
    [_denominator release];
    [super dealloc];
}
- (AXMathExpression *)numeratorExpression { return _numerator; }
- (AXMathExpression *)denimonatorExpression { return _denominator; }
@end

@implementation AXMathExpressionMultiscript {
    AXMathExpression *_base;
    NSArray *_pre, *_post;
}
- (instancetype)initWithBaseExpression:(AXMathExpression *)base
                  prescriptExpressions:(NSArray<AXMathExpressionSubSuperscript *> *)pre
                 postscriptExpressions:(NSArray<AXMathExpressionSubSuperscript *> *)post
{
    if ((self = [super init])) {
        _base = [base retain];
        _pre = [pre copy];
        _post = [post copy];
    }
    return self;
}
- (void)dealloc
{
    [_base release];
    [_pre release];
    [_post release];
    [super dealloc];
}
- (AXMathExpression *)baseExpression { return _base; }
- (NSArray<AXMathExpressionSubSuperscript *> *)prescriptExpressions { return _pre; }
- (NSArray<AXMathExpressionSubSuperscript *> *)postscriptExpressions { return _post; }
@end

@implementation AXMathExpressionRoot {
    NSArray *_radicand;
    AXMathExpression *_index;
}
- (instancetype)initWithRadicandExpressions:(NSArray<AXMathExpression *> *)radicand rootIndexExpression:(AXMathExpression *)index
{
    if ((self = [super init])) {
        _radicand = [radicand copy];
        _index = [index retain];
    }
    return self;
}
- (void)dealloc
{
    [_radicand release];
    [_index release];
    [super dealloc];
}
- (NSArray<AXMathExpression *> *)radicandExpressions { return _radicand; }
- (AXMathExpression *)rootIndexExpression { return _index; }
@end

#pragma mark - Braille maps

/* A grid of pin heights (0 lowered to 1 raised), the size of a typical graphics display. */
@implementation AXBrailleMap {
    CGSize _dimensions;
    float *_heights;
}

+ (BOOL)supportsSecureCoding { return YES; }

- (instancetype)_finchInitWithDimensions:(CGSize)size
{
    if ((self = [super init])) {
        _dimensions = size;
        _heights = calloc((size_t)(size.width * size.height), sizeof(float));
    }
    return self;
}

- (instancetype)init { return [self _finchInitWithDimensions:CGSizeMake(40, 24)]; }

- (void)dealloc
{
    free(_heights);
    [super dealloc];
}

- (CGSize)dimensions { return _dimensions; }

- (NSInteger)_finchIndex:(CGPoint)p
{
    if (p.x < 0 || p.y < 0 || p.x >= _dimensions.width || p.y >= _dimensions.height)
        return -1;
    return (NSInteger)p.y * (NSInteger)_dimensions.width + (NSInteger)p.x;
}

- (void)setHeight:(float)height atPoint:(CGPoint)point
{
    NSInteger i = [self _finchIndex:point];
    if (i >= 0)
        _heights[i] = fminf(fmaxf(height, 0), 1);
}

- (float)heightAtPoint:(CGPoint)point
{
    NSInteger i = [self _finchIndex:point];
    return i >= 0 ? _heights[i] : 0;
}

/* The image scaled to the grid; each pin rises with the darkness under it. */
- (void)presentImage:(CGImageRef)image
{
    size_t w = (size_t)_dimensions.width, h = (size_t)_dimensions.height;
    if (!image || !w || !h)
        return;
    uint8_t *gray = calloc(w * h, 1);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(gray, w, h, 8, w, space, (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(space);
    if (ctx) {
        CGContextSetGrayFillColor(ctx, 1, 1);
        CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
        CGContextRelease(ctx);
        for (size_t i = 0; i < w * h; i++)
            _heights[i] = 1.0f - gray[i] / 255.0f;
    }
    free(gray);
}

- (id)copyWithZone:(NSZone *)zone
{
    AXBrailleMap *m = [[AXBrailleMap allocWithZone:zone] _finchInitWithDimensions:_dimensions];
    memcpy(m->_heights, _heights, (size_t)(_dimensions.width * _dimensions.height) * sizeof(float));
    return m;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeDouble:_dimensions.width forKey:@"width"];
    [coder encodeDouble:_dimensions.height forKey:@"height"];
    [coder encodeBytes:(const uint8_t *)_heights length:(NSUInteger)(_dimensions.width * _dimensions.height) * sizeof(float)
                forKey:@"heights"];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if ((self = [self _finchInitWithDimensions:CGSizeMake([coder decodeDoubleForKey:@"width"], [coder decodeDoubleForKey:@"height"])])) {
        NSUInteger len = 0;
        const uint8_t *b = [coder decodeBytesForKey:@"heights" returnedLength:&len];
        memcpy(_heights, b, MIN(len, (NSUInteger)(_dimensions.width * _dimensions.height) * sizeof(float)));
    }
    return self;
}

@end

#pragma mark - Braille translation

/*
 * Finch's one table: uncontracted (grade 1) English braille, six-dot, written as Unicode
 * braille patterns (U+2800 plus the dot bits). Capitals take the capital sign (dot 6),
 * digits the number sign (dots 3456) and the letters a-j.
 */
static NSString *const kGrade1Identifier = @"org.finch.braille.en-us-g1";

static const uint8_t letter_dots[26] = {
    0x01, 0x03, 0x09, 0x19, 0x11, 0x0B, 0x1B, 0x13, 0x0A, 0x1A, /* a-j */
    0x05, 0x07, 0x0D, 0x1D, 0x15, 0x0F, 0x1F, 0x17, 0x0E, 0x1E, /* k-t */
    0x25, 0x27, 0x3A, 0x2D, 0x3D, 0x35,                         /* u-z */
};

static const struct {
    unichar c;
    uint8_t dots;
} punct_dots[] = {
    {',', 0x02}, {';', 0x06}, {':', 0x12}, {'.', 0x32}, {'!', 0x16}, {'?', 0x26}, {'\'', 0x04}, {'-', 0x24},
    {'(', 0x36}, {')', 0x36}, {'"', 0x26}, {'/', 0x0C}, {'@', 0x08},
};

static const uint8_t kCapitalSign = 0x20, kNumberSign = 0x3C;

@implementation AXBrailleTable {
    NSString *_identifier;
}

+ (NSSet<NSLocale *> *)supportedLocales { return [NSSet setWithObject:[NSLocale localeWithLocaleIdentifier:@"en_US"]]; }

+ (AXBrailleTable *)defaultTableForLocale:(NSLocale *)locale
{
    return [[locale languageCode] isEqualToString:@"en"] ? [[[self alloc] initWithIdentifier:kGrade1Identifier] autorelease] : nil;
}

+ (NSSet<AXBrailleTable *> *)tablesForLocale:(NSLocale *)locale
{
    AXBrailleTable *t = [self defaultTableForLocale:locale];
    return t ? [NSSet setWithObject:t] : [NSSet set];
}

+ (NSSet<AXBrailleTable *> *)languageAgnosticTables { return [NSSet set]; }

- (instancetype)initWithIdentifier:(NSString *)identifier
{
    if (![identifier isEqualToString:kGrade1Identifier]) {
        [self release];
        return nil;
    }
    if ((self = [super init]))
        _identifier = [identifier copy];
    return self;
}

- (void)dealloc
{
    [_identifier release];
    [super dealloc];
}

- (NSString *)identifier { return _identifier; }
- (NSString *)localizedName { return @"English (Uncontracted)"; }
- (NSString *)providerIdentifier { return @"org.finch.braille"; }
- (NSString *)localizedProviderName { return @"Finch"; }
- (NSString *)language { return @"en"; }
- (NSSet<NSLocale *> *)locales { return [[self class] supportedLocales]; }
- (BOOL)isEightDot { return NO; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (BOOL)isEqual:(id)o { return [o isKindOfClass:[AXBrailleTable class]] && [[o identifier] isEqualToString:_identifier]; }
- (NSUInteger)hash { return [_identifier hash]; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_identifier forKey:@"identifier"]; }
- (instancetype)initWithCoder:(NSCoder *)coder { return [self initWithIdentifier:[coder decodeObjectForKey:@"identifier"]]; }

@end

@implementation AXBrailleTranslationResult {
    NSString *_result;
    NSArray *_map;
}

- (instancetype)_finchInitWithResult:(NSString *)result locationMap:(NSArray *)map
{
    if ((self = [super init])) {
        _result = [result copy];
        _map = [map copy];
    }
    return self;
}

- (void)dealloc
{
    [_result release];
    [_map release];
    [super dealloc];
}

- (NSString *)resultString { return _result; }
- (NSArray<NSNumber *> *)locationMap { return _map; }
- (id)copyWithZone:(NSZone *)zone { return [self retain]; }
- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_result forKey:@"result"];
    [coder encodeObject:_map forKey:@"map"];
}
- (instancetype)initWithCoder:(NSCoder *)coder
{
    return [self _finchInitWithResult:[coder decodeObjectForKey:@"result"] locationMap:[coder decodeObjectForKey:@"map"]];
}

@end

@implementation AXBrailleTranslator {
    AXBrailleTable *_table;
}

- (instancetype)initWithBrailleTable:(AXBrailleTable *)table
{
    if ((self = [super init]))
        _table = [table retain];
    return self;
}

- (void)dealloc
{
    [_table release];
    [super dealloc];
}

static unichar
cell(uint8_t dots)
{
    return (unichar)(0x2800 + dots);
}

/* The result's location map gives, for each braille cell, the print index it came from. */
- (AXBrailleTranslationResult *)translatePrintText:(NSString *)text
{
    NSMutableString *out = [NSMutableString string];
    NSMutableArray *map = [NSMutableArray array];
    BOOL inNumber = NO;
    for (NSUInteger i = 0; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        NSNumber *at = @(i);
        if (c >= '0' && c <= '9') {
            if (!inNumber) {
                [out appendFormat:@"%C", cell(kNumberSign)];
                [map addObject:at];
                inNumber = YES;
            }
            [out appendFormat:@"%C", cell(letter_dots[c == '0' ? 9 : c - '1'])];
            [map addObject:at];
            continue;
        }
        inNumber = NO;
        if (c >= 'A' && c <= 'Z') {
            [out appendFormat:@"%C%C", cell(kCapitalSign), cell(letter_dots[c - 'A'])];
            [map addObjectsFromArray:@[ at, at ]];
        } else if (c >= 'a' && c <= 'z') {
            [out appendFormat:@"%C", cell(letter_dots[c - 'a'])];
            [map addObject:at];
        } else if (c == ' ' || c == '\n' || c == '\t') {
            [out appendFormat:@"%C", (unichar)(c == ' ' ? cell(0) : c)];
            [map addObject:at];
        } else {
            uint8_t dots = 0;
            for (size_t k = 0; k < sizeof punct_dots / sizeof punct_dots[0]; k++)
                if (punct_dots[k].c == c)
                    dots = punct_dots[k].dots;
            [out appendFormat:@"%C", (unichar)(dots ? cell(dots) : c)];
            [map addObject:at];
        }
    }
    return [[[AXBrailleTranslationResult alloc] _finchInitWithResult:out locationMap:map] autorelease];
}

- (AXBrailleTranslationResult *)backTranslateBraille:(NSString *)braille
{
    NSMutableString *out = [NSMutableString string];
    NSMutableArray *map = [NSMutableArray array];
    BOOL capital = NO, number = NO;
    for (NSUInteger i = 0; i < [braille length]; i++) {
        unichar c = [braille characterAtIndex:i];
        if (c < 0x2800 || c > 0x28FF) {
            [out appendFormat:@"%C", c];
            [map addObject:@(i)];
            number = NO;
            continue;
        }
        uint8_t dots = (uint8_t)(c - 0x2800);
        if (dots == kCapitalSign) {
            capital = YES;
            continue;
        }
        if (dots == kNumberSign) {
            number = YES;
            continue;
        }
        if (dots == 0) {
            [out appendString:@" "];
            [map addObject:@(i)];
            number = NO;
            continue;
        }
        unichar print = 0;
        for (int k = 0; k < 26 && !print; k++)
            if (letter_dots[k] == dots)
                print = number && k < 10 ? (k == 9 ? '0' : '1' + k) : (capital ? 'A' : 'a') + k;
        for (size_t k = 0; k < sizeof punct_dots / sizeof punct_dots[0] && !print; k++)
            if (punct_dots[k].dots == dots)
                print = punct_dots[k].c;
        if (!print)
            print = c;
        [out appendFormat:@"%C", print];
        [map addObject:@(i)];
        capital = NO;
        if (!(print >= '0' && print <= '9'))
            number = NO;
    }
    return [[[AXBrailleTranslationResult alloc] _finchInitWithResult:out locationMap:map] autorelease];
}

@end

#pragma mark - Colour names

/*
 * A colour's name as VoiceOver speaks it: a hue name ("red", "yellow orange"...), or a
 * grey for colours without much saturation, with "dark" or "light" by lightness.
 */
NSString *
AXNameFromColor(CGColorRef color)
{
    CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef converted = CGColorCreateCopyByMatchingToColorSpace(rgb, kCGRenderingIntentDefault, color, NULL);
    CGColorSpaceRelease(rgb);
    double r = 0, g = 0, b = 0;
    if (converted && CGColorGetNumberOfComponents(converted) >= 3) {
        const CGFloat *c = CGColorGetComponents(converted);
        r = c[0], g = c[1], b = c[2];
    }
    if (converted)
        CGColorRelease(converted);
    double max = fmax(r, fmax(g, b)), min = fmin(r, fmin(g, b)), light = (max + min) / 2, chroma = max - min;
    if (chroma < 0.1) {
        if (light > 0.9)
            return @"white";
        if (light < 0.1)
            return @"black";
        return light < 0.35 ? @"dark gray" : light > 0.75 ? @"light gray" : @"gray";
    }
    double hue;
    if (max == r)
        hue = fmod((g - b) / chroma + 6, 6);
    else if (max == g)
        hue = (b - r) / chroma + 2;
    else
        hue = (r - g) / chroma + 4;
    hue *= 60;
    static const struct {
        double upTo;
        NSString *name;
    } hues[] = {
        {15, @"red"},      {35, @"orange"}, {45, @"yellow orange"}, {65, @"yellow"}, {80, @"yellow green"},
        {160, @"green"},   {190, @"cyan"},  {250, @"blue"},         {290, @"purple"}, {335, @"pink"},
        {360, @"red"},
    };
    NSString *name = @"red";
    for (size_t i = 0; i < sizeof hues / sizeof hues[0]; i++)
        if (hue < hues[i].upTo) {
            name = hues[i].name;
            break;
        }
    /* fully saturated primaries read as dark, as VoiceOver's do; pale colours as light */
    double saturation = chroma / (1 - fabs(2 * light - 1) + 1e-9);
    if (light < 0.3 || (light <= 0.5 && saturation > 0.9 && ![name containsString:@"yellow"] && ![name isEqualToString:@"orange"] &&
                        ![name isEqualToString:@"green"]))
        return [@"dark " stringByAppendingString:name];
    if (light > 0.8)
        return [@"light " stringByAppendingString:name];
    return name;
}
