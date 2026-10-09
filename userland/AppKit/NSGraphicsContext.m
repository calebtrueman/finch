/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSGraphicsContext: a CGContext and how AppKit draws into it. The rendering
 * options (antialiasing, interpolation, compositing, intent, pattern phase)
 * live in the CGContext's graphics state, as Apple's, so CGContextSaveGState
 * and -saveGraphicsState save them alike.
 *
 * The current context is per thread, with a per-thread stack for
 * +saveGraphicsState and +restoreGraphicsState.
 */
#import "AppKitDrawing.h"
#include <pthread.h>

NSGraphicsContextAttributeKey NSGraphicsContextDestinationAttributeName = @"NSGraphicsContextDestinationAttributeName";
NSGraphicsContextAttributeKey NSGraphicsContextRepresentationFormatAttributeName = @"NSGraphicsContextRepresentationFormatAttributeName";
NSGraphicsContextRepresentationFormatName NSGraphicsContextPSFormat = @"NSGraphicsContextPSFormat";
NSGraphicsContextRepresentationFormatName NSGraphicsContextPDFFormat = @"NSGraphicsContextPDFFormat";

void
FinchDrawRaise(NSString *name, NSString *format, ...)
{
    va_list ap;
    va_start(ap, format);
    NSString *reason = [[[NSString alloc] initWithFormat:format arguments:ap] autorelease];
    va_end(ap);
    @throw [NSException exceptionWithName:name reason:reason userInfo:nil];
}

/* MARK: - Per-thread state */

typedef struct {
    NSGraphicsContext *current;  /* retained */
    NSMutableArray *stack;       /* contexts saved by +saveGraphicsState (NSNull for none) */
} GCThreadState;

static pthread_key_t state_key;

static void state_free(void *p);
static void make_key(void) { pthread_key_create(&state_key, state_free); }

static void
state_free(void *p)
{
    GCThreadState *s = p;
    [s->current release];
    [s->stack release];
    free(s);
}

static GCThreadState *
thread_state(void)
{
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, make_key);
    GCThreadState *s = pthread_getspecific(state_key);
    if (!s) {
        s = calloc(1, sizeof *s);
        pthread_setspecific(state_key, s);
    }
    return s;
}

CGContextRef
FinchCurrentCGContext(void)
{
    return [[NSGraphicsContext currentContext] CGContext];
}

/* NSCompositingOperation numbers Plus Lighter after the (gone) Highlight, then the blend modes; CG's don't skip. */
int
FinchCompositeOperation(NSCompositingOperation op)
{
    if (op <= NSCompositingOperationPlusDarker)
        return (int)op;
    if (op == NSCompositingOperationHighlight)
        return 2;
    if (op <= NSCompositingOperationLuminosity)
        return (int)op - 1;
    return -1;
}

/* MARK: - NSGraphicsContext */

@implementation NSGraphicsContext {
    CGContextRef _cg;
    BOOL _flipped;
    id _destination;  /* the bitmap rep drawn into, kept alive with the context */
    NSDictionary *_attributes;
    id _focusStack;
}

- (instancetype)_initWithCGContext:(CGContextRef)cg flipped:(BOOL)flipped
{
    if ((self = [super init])) {
        _cg = CGContextRetain(cg);
        _flipped = flipped;
    }
    return self;
}

- (void)dealloc
{
    CGContextRelease(_cg);
    [_destination release];
    [_attributes release];
    [_focusStack release];
    [super dealloc];
}

+ (NSGraphicsContext *)graphicsContextWithCGContext:(CGContextRef)graphicsPort flipped:(BOOL)initialFlippedState
{
    if (!graphicsPort)
        return nil;
    return [[[self alloc] _initWithCGContext:graphicsPort flipped:initialFlippedState] autorelease];
}

+ (NSGraphicsContext *)graphicsContextWithGraphicsPort:(void *)graphicsPort flipped:(BOOL)initialFlippedState
{
    return [self graphicsContextWithCGContext:(CGContextRef)graphicsPort flipped:initialFlippedState];
}

+ (NSGraphicsContext *)graphicsContextWithBitmapImageRep:(NSBitmapImageRep *)bitmapRep
{
    if (![bitmapRep isKindOfClass:[NSBitmapImageRep class]])
        return nil;
    CGContextRef cg = [bitmapRep _finchCreateCGContext];
    if (!cg)
        return nil;
    NSGraphicsContext *g = [[self alloc] _initWithCGContext:cg flipped:NO];
    CGContextRelease(cg);
    g->_destination = [bitmapRep retain];
    return [g autorelease];
}

+ (NSGraphicsContext *)graphicsContextWithAttributes:(NSDictionary<NSGraphicsContextAttributeKey, id> *)attributes
{
    id dest = attributes[NSGraphicsContextDestinationAttributeName];
    if ([dest isKindOfClass:[NSBitmapImageRep class]])
        return [self graphicsContextWithBitmapImageRep:dest];
    if ([dest isKindOfClass:NSClassFromString(@"NSWindow")])
        return [self graphicsContextWithWindow:dest];
    return nil;
}

+ (NSGraphicsContext *)graphicsContextWithWindow:(NSWindow *)window
{
    return [window respondsToSelector:@selector(graphicsContext)] ? [window graphicsContext] : nil;
}

+ (NSGraphicsContext *)currentContext
{
    return thread_state()->current;
}

+ (void)setCurrentContext:(NSGraphicsContext *)context
{
    GCThreadState *s = thread_state();
    if (s->current == context)
        return;
    [context retain];
    [s->current release];
    s->current = context;
}

+ (BOOL)currentContextDrawingToScreen
{
    NSGraphicsContext *c = [self currentContext];
    return c ? [c isDrawingToScreen] : YES;
}

+ (void)saveGraphicsState
{
    GCThreadState *s = thread_state();
    if (!s->stack)
        s->stack = [[NSMutableArray alloc] init];
    [s->stack addObject:s->current ?: (id)[NSNull null]];
    [s->current saveGraphicsState];
}

+ (void)restoreGraphicsState
{
    GCThreadState *s = thread_state();
    if (!s->stack.count)
        return;
    id saved = [[s->stack lastObject] retain];
    [s->stack removeLastObject];
    NSGraphicsContext *c = saved == [NSNull null] ? nil : saved;
    [self setCurrentContext:c];
    [c restoreGraphicsState];
    [saved release];
}

+ (void)setGraphicsState:(NSInteger)gState
{
}

- (NSDictionary *)attributes { return _attributes; }
- (BOOL)isDrawingToScreen { return YES; }
- (BOOL)isFlipped { return _flipped; }
- (CGContextRef)CGContext { return _cg; }
- (void *)graphicsPort { return _cg; }
- (CIContext *)CIContext { return nil; }
- (id)focusStack { return _focusStack; }

- (void)setFocusStack:(id)stack
{
    [stack retain];
    [_focusStack release];
    _focusStack = stack;
}

- (void)saveGraphicsState { CGContextSaveGState(_cg); }
- (void)restoreGraphicsState { CGContextRestoreGState(_cg); }

- (void)flushGraphics
{
    CGContextFlush(_cg);
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p>", [self class], self];
}

/* MARK: Rendering options */

- (BOOL)shouldAntialias { return CGContextGetShouldAntialias(_cg); }
- (void)setShouldAntialias:(BOOL)flag { CGContextSetShouldAntialias(_cg, flag); }
- (NSImageInterpolation)imageInterpolation { return (NSImageInterpolation)CGContextGetInterpolationQuality(_cg); }
- (void)setImageInterpolation:(NSImageInterpolation)interpolation { CGContextSetInterpolationQuality(_cg, (CGInterpolationQuality)interpolation); }
- (NSColorRenderingIntent)colorRenderingIntent { return (NSColorRenderingIntent)CGContextGetRenderingIntent(_cg); }
- (void)setColorRenderingIntent:(NSColorRenderingIntent)intent { CGContextSetRenderingIntent(_cg, (CGColorRenderingIntent)intent); }

- (NSPoint)patternPhase
{
    CGSize s = CGContextGetPatternPhase(_cg);
    return NSMakePoint(s.width, s.height);
}

- (void)setPatternPhase:(NSPoint)phase
{
    CGContextSetPatternPhase(_cg, CGSizeMake(phase.x, phase.y));
}

/* Porter-Duff operations read back as themselves; a blend mode reads back as source over, as Apple's. */
- (NSCompositingOperation)compositingOperation
{
    int op = CGContextGetCompositeOperation(_cg);
    if (op <= 11)
        return (NSCompositingOperation)op;
    return op == 12 ? NSCompositingOperationPlusLighter : NSCompositingOperationSourceOver;
}

- (void)setCompositingOperation:(NSCompositingOperation)operation
{
    int op = FinchCompositeOperation(operation);
    if (op < 0)
        FinchDrawRaise(NSInvalidArgumentException, @"%ld is not a valid NSCompositingOperation", (long)operation);
    CGContextSetCompositeOperation(_cg, op);
}

@end
