/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * RecapPerformanceTesting (private): the performance-test runner some of
 * Apple's apps link (TextEdit runs resize and scroll tests through it when
 * asked to). Finch has no performance recording, so a test "runs" by
 * finishing at once: its completion handler is called and nothing is
 * measured. The classes have the interface apps use.
 */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface RPTTestRunner : NSObject
@property (strong) id delegate, settings, interactionOptions;
@end

@interface RPTResizeTestParameters : NSObject
@property (copy) NSString *testName;
@property (strong) id window, conversion;
@property (copy) void (^completionHandler)(void);
@property CGSize minimumWindowSize, maximumWindowSize;
@end

@interface RPTScrollViewTestParameters : NSObject
@property (copy) NSString *testName;
@property (strong) id conversion, curveFunction;
@property (copy) void (^completionHandler)(void);
@property CGRect scrollingBounds;
@property double amplitude, amplitudeFactor, scrollingContentLength, iterationDurationFactor;
@property NSInteger direction;
@property BOOL shouldFlick, preventSheetDismissal;
@property NSUInteger forceMinVersion, forceMaxVersion;
@end

static void
finish(id parameters)
{
    void (^done)(void) = [parameters respondsToSelector:@selector(completionHandler)] ? [parameters completionHandler] : nil;
    if (done)
        dispatch_async(dispatch_get_main_queue(), done);
}

@implementation RPTTestRunner
@synthesize delegate = _delegate, settings = _settings, interactionOptions = _interactionOptions;

+ (BOOL)isRecapAvailable { return NO; }
+ (void)runTestWithParameters:(id)parameters { finish(parameters); }
+ (void)runTestWithParameters:(id)parameters delegate:(id)delegate { finish(parameters); }
+ (void)runTestWithParameters:(id)parameters resultHandler:(void (^)(id))handler
{
    finish(parameters);
    if (handler)
        handler(nil);
}
+ (void)playInteraction:(id)interaction completionHandler:(void (^)(id))handler
{
    if (handler)
        handler(nil);
}

- (instancetype)initWithInteractionOptions:(id)options
{
    self = [super init];
    if (self)
        _interactionOptions = [options retain];
    return self;
}

- (void)dealloc
{
    [_delegate release];
    [_settings release];
    [_interactionOptions release];
    [super dealloc];
}

- (BOOL)checkTestRequirementsWithError:(NSError **)error { return YES; }
- (void)runTestWithParameters:(id)parameters { finish(parameters); }
- (void)runTestWithParameters:(id)parameters resultHandler:(void (^)(id))handler
{
    [[self class] runTestWithParameters:parameters resultHandler:handler];
}
- (void)playInteraction:(id)interaction completionHandler:(void (^)(id))handler
{
    [[self class] playInteraction:interaction completionHandler:handler];
}

@end

@implementation RPTResizeTestParameters
@synthesize testName = _testName, window = _window, conversion = _conversion, completionHandler = _completionHandler,
            minimumWindowSize = _min, maximumWindowSize = _max;

- (instancetype)initWithTestName:(NSString *)name window:(id)window completionHandler:(void (^)(void))handler
{
    self = [super init];
    if (self) {
        _testName = [name copy];
        _window = [window retain];
        _completionHandler = [handler copy];
    }
    return self;
}

- (void)dealloc
{
    [_testName release];
    [_window release];
    [_conversion release];
    [_completionHandler release];
    [super dealloc];
}

- (id)composerBlock { return nil; }
- (void)prepareWithComposer:(id)composer {}

@end

@implementation RPTScrollViewTestParameters
@synthesize testName = _testName, conversion = _conversion, curveFunction = _curve, completionHandler = _completionHandler,
            scrollingBounds = _bounds, amplitude = _amplitude, amplitudeFactor = _factor,
            scrollingContentLength = _length, iterationDurationFactor = _duration, direction = _direction,
            shouldFlick = _flick, preventSheetDismissal = _preventSheet, forceMinVersion = _minV,
            forceMaxVersion = _maxV;

- (instancetype)initWithTestName:(NSString *)name scrollBounds:(CGRect)bounds amplitude:(double)amplitude
                       direction:(NSInteger)direction completionHandler:(void (^)(void))handler
{
    self = [super init];
    if (self) {
        _testName = [name copy];
        _bounds = bounds;
        _amplitude = amplitude;
        _direction = direction;
        _completionHandler = [handler copy];
    }
    return self;
}

- (instancetype)initWithTestName:(NSString *)name scrollBounds:(CGRect)bounds scrollContentLength:(double)length
                       direction:(NSInteger)direction completionHandler:(void (^)(void))handler
{
    self = [self initWithTestName:name scrollBounds:bounds amplitude:0 direction:direction completionHandler:handler];
    if (self)
        _length = length;
    return self;
}

- (instancetype)initWithTestName:(NSString *)name scrollViewIdentifier:(NSString *)identifier
                    scrollBounds:(CGRect)bounds scrollContentLength:(double)length direction:(NSInteger)direction
               completionHandler:(void (^)(void))handler
{
    return [self initWithTestName:name scrollBounds:bounds scrollContentLength:length direction:direction
                completionHandler:handler];
}

- (instancetype)initWithTestName:(NSString *)name scrollView:(id)scrollView completionHandler:(void (^)(void))handler
{
    return [self initWithTestName:name scrollBounds:CGRectMake(0, 0, 0, 0) amplitude:0 direction:0 completionHandler:handler];
}

- (void)dealloc
{
    [_testName release];
    [_conversion release];
    [_curve release];
    [_completionHandler release];
    [super dealloc];
}

- (id)composerBlock { return nil; }
- (void)prepareWithComposer:(id)composer {}

@end
