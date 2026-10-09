/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CATransform3D's functions and CACurrentMediaTime. Transforms are row
 * vector matrices, as Core Animation's: Concat(a, b) applies a, then b;
 * Translate, Scale and Rotate apply their change before t.
 */
#import <QuartzCore/QuartzCore.h>
#include <mach/mach_time.h>

const CATransform3D CATransform3DIdentity = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};

CFTimeInterval
CACurrentMediaTime(void)
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom)
        mach_timebase_info(&tb);
    return (CFTimeInterval)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

bool
CATransform3DIsIdentity(CATransform3D t)
{
    return CATransform3DEqualToTransform(t, CATransform3DIdentity);
}

bool
CATransform3DEqualToTransform(CATransform3D a, CATransform3D b)
{
    return memcmp(&a, &b, sizeof a) == 0 ||
           (a.m11 == b.m11 && a.m12 == b.m12 && a.m13 == b.m13 && a.m14 == b.m14 && a.m21 == b.m21 && a.m22 == b.m22 &&
            a.m23 == b.m23 && a.m24 == b.m24 && a.m31 == b.m31 && a.m32 == b.m32 && a.m33 == b.m33 && a.m34 == b.m34 &&
            a.m41 == b.m41 && a.m42 == b.m42 && a.m43 == b.m43 && a.m44 == b.m44);
}

CATransform3D
CATransform3DMakeTranslation(CGFloat tx, CGFloat ty, CGFloat tz)
{
    CATransform3D t = CATransform3DIdentity;
    t.m41 = tx, t.m42 = ty, t.m43 = tz;
    return t;
}

CATransform3D
CATransform3DMakeScale(CGFloat sx, CGFloat sy, CGFloat sz)
{
    CATransform3D t = CATransform3DIdentity;
    t.m11 = sx, t.m22 = sy, t.m33 = sz;
    return t;
}

/* A rotation of angle radians about the vector (x, y, z); a zero vector means no rotation. */
CATransform3D
CATransform3DMakeRotation(CGFloat angle, CGFloat x, CGFloat y, CGFloat z)
{
    CGFloat len = sqrt(x * x + y * y + z * z);
    if (len == 0)
        return CATransform3DIdentity;
    x /= len, y /= len, z /= len;
    CGFloat c = cos(angle), s = sin(angle), k = 1 - c;
    CATransform3D t = CATransform3DIdentity;
    t.m11 = x * x * k + c, t.m12 = x * y * k + z * s, t.m13 = x * z * k - y * s;
    t.m21 = y * x * k - z * s, t.m22 = y * y * k + c, t.m23 = y * z * k + x * s;
    t.m31 = z * x * k + y * s, t.m32 = z * y * k - x * s, t.m33 = z * z * k + c;
    return t;
}

CATransform3D
CATransform3DConcat(CATransform3D a, CATransform3D b)
{
    const CGFloat *p = &a.m11, *q = &b.m11;
    CATransform3D r;
    CGFloat *o = &r.m11;
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            o[i * 4 + j] = p[i * 4] * q[j] + p[i * 4 + 1] * q[4 + j] + p[i * 4 + 2] * q[8 + j] + p[i * 4 + 3] * q[12 + j];
    return r;
}

CATransform3D
CATransform3DTranslate(CATransform3D t, CGFloat tx, CGFloat ty, CGFloat tz)
{
    return CATransform3DConcat(CATransform3DMakeTranslation(tx, ty, tz), t);
}

CATransform3D
CATransform3DScale(CATransform3D t, CGFloat sx, CGFloat sy, CGFloat sz)
{
    return CATransform3DConcat(CATransform3DMakeScale(sx, sy, sz), t);
}

CATransform3D
CATransform3DRotate(CATransform3D t, CGFloat angle, CGFloat x, CGFloat y, CGFloat z)
{
    return CATransform3DConcat(CATransform3DMakeRotation(angle, x, y, z), t);
}

/* The inverse, or t itself when it has none. */
CATransform3D
CATransform3DInvert(CATransform3D t)
{
    double m[16], inv[16];
    const CGFloat *p = &t.m11;
    for (int i = 0; i < 16; i++)
        m[i] = p[i];
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
    double det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    if (fabs(det) < 1e-12)
        return t;
    CATransform3D r;
    CGFloat *o = &r.m11;
    for (int i = 0; i < 16; i++)
        o[i] = inv[i] / det;
    return r;
}

CATransform3D
CATransform3DMakeAffineTransform(CGAffineTransform m)
{
    CATransform3D t = CATransform3DIdentity;
    t.m11 = m.a, t.m12 = m.b, t.m21 = m.c, t.m22 = m.d, t.m41 = m.tx, t.m42 = m.ty;
    return t;
}

bool
CATransform3DIsAffine(CATransform3D t)
{
    return t.m13 == 0 && t.m14 == 0 && t.m23 == 0 && t.m24 == 0 && t.m31 == 0 && t.m32 == 0 && t.m33 == 1 &&
           t.m34 == 0 && t.m43 == 0 && t.m44 == 1;
}

CGAffineTransform
CATransform3DGetAffineTransform(CATransform3D t)
{
    return CGAffineTransformMake(t.m11, t.m12, t.m21, t.m22, t.m41, t.m42);
}
