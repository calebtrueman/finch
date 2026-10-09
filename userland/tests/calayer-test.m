/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-calayer-test: Core Animation's layers, animations and transactions.
 * Defaults, geometry, the tree, actions, animation bookkeeping, timing
 * curves, the spring's settling time, and a layer tree drawn with
 * -renderInContext: (pixels sampled away from edges). Prints everything;
 * run it against Apple's QuartzCore and Finch's (DYLD_FRAMEWORK_PATH) and diff.
 */
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <stdio.h>

static void
R(const char *label, CGRect r)
{
    printf("%s {%g,%g,%g,%g}\n", label, r.origin.x, r.origin.y, r.size.width, r.size.height);
}

static void
timing(const char *label, CAMediaTimingFunctionName name)
{
    CAMediaTimingFunction *f = [CAMediaTimingFunction functionWithName:name];
    float p[4][2];
    for (int i = 0; i < 4; i++)
        [f getControlPointAtIndex:(size_t)i values:p[i]];
    printf("timing %s: %g %g %g %g %g %g %g %g\n", label, p[0][0], p[0][1], p[1][0], p[1][1], p[2][0], p[2][1], p[3][0],
           p[3][1]);
}

static void
spring(double m, double k, double d, double v)
{
    CASpringAnimation *s = [CASpringAnimation animationWithKeyPath:@"x"];
    s.mass = m, s.stiffness = k, s.damping = d, s.initialVelocity = v;
    printf("spring m %g k %g d %g v %g: settles %.4f\n", m, k, d, v, s.settlingDuration);
}

@interface Watcher : NSObject <CAAnimationDelegate>
@end
@implementation Watcher
- (void)animationDidStart:(CAAnimation *)a { printf("delegate: started\n"); }
- (void)animationDidStop:(CAAnimation *)a finished:(BOOL)f { printf("delegate: stopped finished %d\n", f); }
@end

@interface Drawer : NSObject <CALayerDelegate>
@end
@implementation Drawer
- (void)drawLayer:(CALayer *)layer inContext:(CGContextRef)ctx
{
    CGContextSetRGBFillColor(ctx, 1, 0.5, 0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, 10, 10));
}
@end

static CGColorRef
rgb(double r, double g, double b)
{
    return CGColorCreateSRGB(r, g, b, 1);
}

static void
render(void)
{
    const int W = 200, H = 160;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(NULL, W, H, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);

    CALayer *root = [CALayer layer];
    root.frame = CGRectMake(0, 0, W, H);
    root.backgroundColor = rgb(1, 1, 1);

    CALayer *box = [CALayer layer];
    box.frame = CGRectMake(10, 10, 80, 60);
    box.backgroundColor = rgb(0, 0, 1);
    box.borderWidth = 6;
    box.borderColor = rgb(1, 0, 0);
    [root addSublayer:box];

    CALayer *inner = [CALayer layer];
    inner.frame = CGRectMake(20, 20, 100, 100); /* overflows box: clipped */
    inner.backgroundColor = rgb(0, 1, 0);
    box.masksToBounds = YES;
    [box addSublayer:inner];

    CAShapeLayer *shape = [CAShapeLayer layer];
    shape.frame = CGRectMake(110, 10, 80, 60);
    CGPathRef path = CGPathCreateWithEllipseInRect(CGRectMake(0, 0, 80, 60), NULL);
    shape.path = path;
    CGPathRelease(path);
    shape.fillColor = rgb(1, 1, 0);
    [root addSublayer:shape];

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = CGRectMake(10, 90, 80, 60);
    grad.colors = @[ (__bridge id)rgb(0, 0, 0), (__bridge id)rgb(1, 1, 1) ];
    [root addSublayer:grad];

    CALayer *half = [CALayer layer];
    half.frame = CGRectMake(110, 90, 80, 60);
    half.backgroundColor = rgb(0, 0, 0);
    half.opacity = 0.5;
    half.affineTransform = CGAffineTransformMakeScale(0.5, 0.5);
    [root addSublayer:half];

    static Drawer *drawer;
    drawer = [[Drawer alloc] init];
    CALayer *drawn = [CALayer layer];
    drawn.frame = CGRectMake(170, 130, 20, 20);
    drawn.delegate = drawer;
    [drawn setNeedsDisplay];
    [root addSublayer:drawn];

    [root renderInContext:cg];
    const uint8_t *px = CGBitmapContextGetData(cg);
    size_t bpr = CGBitmapContextGetBytesPerRow(cg);
    /* points in the layer's coordinates (y up); the bitmap's rows run top down */
    static const struct {
        const char *label;
        int x, y;
    } at[] = {
        {"background", 100, 80},  {"box", 20, 25},       {"border", 12, 40},       {"inner", 50, 50},
        {"clipped", 95, 75},      {"ellipse", 150, 40},  {"ellipse corner", 112, 12}, {"gradient low", 50, 93},
        {"gradient high", 50, 147}, {"half", 150, 120},  {"half outside", 120, 95}, {"drawn", 175, 135},
        {"drawn rest", 185, 145},
    };
    for (size_t i = 0; i < sizeof at / sizeof at[0]; i++) {
        const uint8_t *p = px + (size_t)(H - 1 - at[i].y) * bpr + (size_t)at[i].x * 4;
        /* to sixteenths, so blending's rounding doesn't show */
        printf("pixel %s: %d %d %d\n", at[i].label, (p[0] + 8) / 16, (p[1] + 8) / 16, (p[2] + 8) / 16);
    }
    CGContextRelease(cg);
}

int
main(void)
{
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0);
        Dl_info info;
        dladdr((__bridge void *)[CALayer class], &info);
        printf("%s\n", info.dli_fname);

        CALayer *l = [CALayer layer];
        R("bounds", l.bounds);
        printf("pos %g,%g anchor %g,%g z %g opacity %g hidden %d masks %d doubleSided %d flipped %d\n", l.position.x,
               l.position.y, l.anchorPoint.x, l.anchorPoint.y, l.zPosition, l.opacity, l.isHidden, l.masksToBounds,
               l.isDoubleSided, l.isGeometryFlipped);
        printf("gravity %s filters %s %s scale %g corner %g border %g shadow %g offset %g,%g radius %g edges %u\n",
               l.contentsGravity.UTF8String, l.minificationFilter.UTF8String, l.magnificationFilter.UTF8String,
               l.contentsScale, l.cornerRadius, l.borderWidth, l.shadowOpacity, l.shadowOffset.width,
               l.shadowOffset.height, l.shadowRadius, (unsigned)l.edgeAntialiasingMask);
        printf("background %s border %s shadow %s\n", l.backgroundColor ? "set" : "nil", l.borderColor ? "set" : "nil",
               l.shadowColor ? "set" : "nil");

        l.frame = CGRectMake(10, 20, 100, 50);
        R("bounds after frame", l.bounds);
        printf("pos %g,%g\n", l.position.x, l.position.y);
        l.anchorPoint = CGPointMake(0, 0);
        R("frame after anchor", l.frame);
        l.transform = CATransform3DMakeScale(2, 2, 1);
        R("frame scaled", l.frame);
        l.transform = CATransform3DIdentity;
        l.anchorPoint = CGPointMake(0.5, 0.5);
        CALayer *s = [CALayer layer];
        s.frame = CGRectMake(5, 5, 20, 20);
        [l addSublayer:s];
        CGPoint p = [s convertPoint:CGPointMake(1, 1) toLayer:l];
        printf("convert %g,%g\n", p.x, p.y);
        l.bounds = CGRectMake(3, 4, 100, 50);
        p = [s convertPoint:CGPointMake(1, 1) toLayer:l];
        printf("convert with bounds origin %g,%g\n", p.x, p.y);
        CALayer *hit = [l hitTest:CGPointMake(10, 10)];
        printf("hit %s\n", hit == s ? "sublayer" : hit == l ? "layer" : "nil");
        printf("contains %d %d\n", [l containsPoint:CGPointMake(3, 4)], [l containsPoint:CGPointMake(200, 4)]);

        CALayer *a = [CALayer layer], *b = [CALayer layer], *c = [CALayer layer];
        [l addSublayer:a];
        [l insertSublayer:b below:a];
        [l insertSublayer:c atIndex:0];
        printf("order %d %d %d %d\n", (int)[l.sublayers indexOfObject:c], (int)[l.sublayers indexOfObject:s],
               (int)[l.sublayers indexOfObject:b], (int)[l.sublayers indexOfObject:a]);
        [l replaceSublayer:b with:[CALayer layer]];
        [a removeFromSuperlayer];
        printf("count %d b's superlayer %s\n", (int)l.sublayers.count, b.superlayer ? "set" : "nil");

        printf("needsDisplay %d", l.needsDisplay);
        [l setNeedsDisplay];
        printf(" then %d\n", l.needsDisplay);
        printf("actions %s %s\n", [[(id)[l actionForKey:@"opacity"] description] UTF8String],
               [[(id)[s actionForKey:@"position"] description] UTF8String]);
        l.actions = @{@"opacity" : [NSNull null]};
        printf("null action %s\n", [[(id)[l actionForKey:@"opacity"] description] UTF8String]);
        printf("default opacity %s needsDisplayForKey %d text %d\n",
               [[CALayer defaultValueForKey:@"opacity"] description].UTF8String, [CALayer needsDisplayForKey:@"bounds"],
               [CATextLayer needsDisplayForKey:@"string"]);
        [l setValue:@42 forKey:@"custom"];
        printf("kvc custom %s\n", [[l valueForKey:@"custom"] description].UTF8String);
        printf("description %s\n", [[l description] substringToIndex:9].UTF8String);

        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        printf("basic: key %s dur %g removed %d fill %s timing %s speed %g additive %d\n", fade.keyPath.UTF8String,
               fade.duration, fade.isRemovedOnCompletion, fade.fillMode.UTF8String, fade.timingFunction ? "set" : "nil",
               fade.speed, fade.isAdditive);
        fade.toValue = @0.5;
        CABasicAnimation *copy = [fade copy];
        printf("copy distinct %d key %s to %s\n", copy != fade, copy.keyPath.UTF8String,
               [[copy.toValue description] UTF8String]);
        Watcher *w = [[Watcher alloc] init];
        fade.delegate = w;
        [l addAnimation:fade forKey:@"fade"];
        printf("keys %s same object %d\n", [[l animationKeys] componentsJoinedByString:@","].UTF8String,
               [l animationForKey:@"fade"] == fade);
        printf("presentation %d model %d\n", l.presentationLayer != nil, l.modelLayer == l);
        CAKeyframeAnimation *k = [CAKeyframeAnimation animationWithKeyPath:@"position"];
        CATransition *t = [CATransition animation];
        printf("keyframe calc %s transition %s %g-%g group %s\n", k.calculationMode.UTF8String, t.type.UTF8String,
               t.startProgress, t.endProgress, [[[CAAnimationGroup animation] animations] description].UTF8String);
        timing("linear", kCAMediaTimingFunctionLinear);
        timing("easeIn", kCAMediaTimingFunctionEaseIn);
        timing("easeOut", kCAMediaTimingFunctionEaseOut);
        timing("easeInEaseOut", kCAMediaTimingFunctionEaseInEaseOut);
        timing("default", kCAMediaTimingFunctionDefault);
        spring(1, 100, 10, 0);
        spring(1, 100, 10, 5);
        spring(2, 100, 10, 0);
        spring(1, 50, 1, 5);
        spring(1, 100, 20, 0);
        spring(1, 4, 4, 0);
        spring(1, 1, 2, 3);

        printf("transaction %g disable %d\n", [CATransaction animationDuration], [CATransaction disableActions]);
        [CATransaction begin];
        [CATransaction setAnimationDuration:2];
        [CATransaction setDisableActions:YES];
        [CATransaction setCompletionBlock:^{
            printf("completion block\n");
        }];
        printf("inside %g disable %d\n", [CATransaction animationDuration], [CATransaction disableActions]);
        [CATransaction commit];
        printf("after %g\n", [CATransaction animationDuration]);

        CATextLayer *text = [CATextLayer layer];
        CAShapeLayer *shape = [CAShapeLayer layer];
        CAGradientLayer *grad = [CAGradientLayer layer];
        printf("text size %g wrapped %d align %s truncation %s\n", text.fontSize, text.wrapped,
               text.alignmentMode.UTF8String, text.truncationMode.UTF8String);
        printf("shape width %g fill %s stroke %s rule %s cap %s join %s miter %g end %g\n", shape.lineWidth,
               shape.fillColor ? "set" : "nil", shape.strokeColor ? "set" : "nil", shape.fillRule.UTF8String,
               shape.lineCap.UTF8String, shape.lineJoin.UTF8String, shape.miterLimit, shape.strokeEnd);
        printf("gradient %s %g,%g to %g,%g\n", grad.type.UTF8String, grad.startPoint.x, grad.startPoint.y,
               grad.endPoint.x, grad.endPoint.y);
        CAReplicatorLayer *rep = [CAReplicatorLayer layer];
        CATiledLayer *tiled = [CATiledLayer layer];
        CAEmitterLayer *em = [CAEmitterLayer layer];
        printf("replicator %ld scroll %s tile %g lod %zu emitter %s %s %s birth %g\n", (long)rep.instanceCount,
               [[CAScrollLayer layer] scrollMode].UTF8String, tiled.tileSize.width, tiled.levelsOfDetail,
               em.emitterShape.UTF8String, em.emitterMode.UTF8String, em.renderMode.UTF8String, em.birthRate);

        render();

        /* the animation's end and the completion block come on the main queue */
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, false);
        printf("keys after %s\n", [[[l animationKeys] componentsJoinedByString:@","] UTF8String]);
    }
    return 0;
}
