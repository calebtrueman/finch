/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-quartzcore-test: QuartzCore's CATransform3D functions and string
 * constants. Prints everything; run it against Apple's QuartzCore and
 * Finch's (DYLD_FRAMEWORK_PATH) and diff.
 */
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <stdio.h>

static void
show(const char *label, CATransform3D t)
{
    const CGFloat *m = &t.m11;
    printf("%s:", label);
    for (int i = 0; i < 16; i++)
        printf(" %.6f", fabs(m[i]) < 5e-7 ? 0.0 : m[i]);
    printf("\n");
}

int
main(void)
{
    Dl_info info;
    dladdr((void *)CATransform3DConcat, &info);
    printf("%s\n", info.dli_fname);
    CATransform3D t = CATransform3DMakeTranslation(1, 2, 3);
    show("identity", CATransform3DIdentity);
    show("translation", t);
    show("scale", CATransform3DMakeScale(2, 3, 4));
    show("rotation z", CATransform3DMakeRotation(M_PI / 3, 0, 0, 1));
    show("rotation axis", CATransform3DMakeRotation(0.7, 1, 2, 3));
    show("rotation zero axis", CATransform3DMakeRotation(0.7, 0, 0, 0));
    show("translate", CATransform3DTranslate(CATransform3DMakeScale(2, 2, 2), 1, 1, 1));
    show("scale t", CATransform3DScale(t, 2, 3, 4));
    show("rotate t", CATransform3DRotate(t, 0.5, 0, 1, 0));
    show("concat", CATransform3DConcat(t, CATransform3DMakeRotation(0.3, 1, 0, 0)));
    show("invert", CATransform3DInvert(CATransform3DRotate(CATransform3DMakeScale(2, 3, 4), 0.5, 1, 1, 0)));
    show("invert singular", CATransform3DInvert(CATransform3DMakeScale(0, 1, 1)));
    CATransform3D p = CATransform3DIdentity;
    p.m34 = -1.0 / 500;
    show("perspective rotate", CATransform3DRotate(p, 0.4, 0, 1, 0));
    CGAffineTransform a = CGAffineTransformMake(1, 2, 3, 4, 5, 6);
    show("from affine", CATransform3DMakeAffineTransform(a));
    CGAffineTransform back = CATransform3DGetAffineTransform(CATransform3DMakeAffineTransform(a));
    printf("affine back: %g %g %g %g %g %g\n", back.a, back.b, back.c, back.d, back.tx, back.ty);
    printf("is identity %d %d affine %d %d equal %d %d\n", CATransform3DIsIdentity(CATransform3DIdentity),
           CATransform3DIsIdentity(t), CATransform3DIsAffine(t), CATransform3DIsAffine(p),
           CATransform3DEqualToTransform(t, CATransform3DMakeTranslation(1, 2, 3)),
           CATransform3DEqualToTransform(t, p));
    printf("media time positive %d\n", CACurrentMediaTime() > 0);
    printf("constants: %s %s %s %s %s %s %s\n", kCAFillModeForwards.UTF8String,
           kCAMediaTimingFunctionEaseInEaseOut.UTF8String, kCATransitionFade.UTF8String,
           kCAGravityResizeAspect.UTF8String, kCAFilterLinear.UTF8String, kCAAlignmentCenter.UTF8String,
           kCAAnimationCubic.UTF8String);
    return 0;
}
