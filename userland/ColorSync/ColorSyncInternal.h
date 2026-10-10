/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* What ColorSync's profiles and transforms share. */
#ifndef COLORSYNC_INTERNAL_H
#define COLORSYNC_INTERNAL_H

#include <ColorSync/ColorSync.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdint.h>
#include "skcms.h"

/* CoreFoundation's runtime (swift-corelibs' CFRuntime.h): a CF type of our own. */
typedef struct {
    uintptr_t isa;
    _Atomic(uint64_t) info;
} CFRuntimeBase;

typedef struct {
    CFIndex version;
    const char *className;
    void (*init)(CFTypeRef);
    CFTypeRef (*copy)(CFAllocatorRef, CFTypeRef);
    void (*finalize)(CFTypeRef);
    Boolean (*equal)(CFTypeRef, CFTypeRef);
    CFHashCode (*hash)(CFTypeRef);
    CFStringRef (*copyFormattingDesc)(CFTypeRef, CFDictionaryRef);
    CFStringRef (*copyDebugDesc)(CFTypeRef);
    void (*reclaim)(CFTypeRef);
    uint32_t (*refcount)(intptr_t, CFTypeRef);
    uintptr_t requiredAlignment;
} CFRuntimeClass;

extern CFTypeID _CFRuntimeRegisterClass(const CFRuntimeClass *cls);
extern CFTypeRef _CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID typeID, CFIndex extraBytes,
                                          unsigned char *category);

uint32_t cs_be32(const uint8_t *p);
CFStringRef cs_string_from_sig(uint32_t sig);
const uint8_t *cs_profile_bytes(ColorSyncProfileRef prof, size_t *len);
uint32_t cs_profile_space(ColorSyncProfileRef prof);
uint32_t cs_profile_pcs(ColorSyncProfileRef prof);

/* How a profile's device values reach D50 XYZ, ColorSync's working space:
   - RGB: three curves, then a matrix;
   - GRAY: one curve, scaling the D50 white;
   - LAB, XYZ: the PCS encodings themselves (Lab as ColorSync's floats carry it,
     L/100, (a+128)/255, (b+128)/255);
   - LUT: anything else skcms can read (A2B / B2A tables), converted by skcms. */
enum { CS_MODEL_RGB, CS_MODEL_GRAY, CS_MODEL_LAB, CS_MODEL_XYZ, CS_MODEL_LUT };

typedef struct {
    int kind;
    int channels;
    skcms_Curve curve[3];
    skcms_TransferFunction inverse[3];
    bool has_inverse[3];
    double m[9], minv[9]; /* device-linear RGB to XYZ, and back */
    uint8_t *bytes;       /* the profile, padded, as skcms reads it */
    skcms_ICCProfile icc;
} cs_model;

/* A profile's model, with its own curves (cs_model_init), or, for transforms, with
   Rec. 709 camera curves shown as BT.1886 displays show them unless use_709_oetf. */
bool cs_model_init(cs_model *m, ColorSyncProfileRef prof, bool as_destination);
bool cs_model_init_with_options(cs_model *m, ColorSyncProfileRef prof, bool as_destination, bool use_709_oetf);
void cs_model_init_pcs(cs_model *m, uint32_t pcs);
void cs_model_free(cs_model *m);
float cs_curve_eval(const skcms_Curve *c, float x);

#endif
