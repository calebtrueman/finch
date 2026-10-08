/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Included into every CoreFoundation source file after swift-corelibs'
 * CoreFoundation_Prefix.h (userland/CoreFoundation/build.sh). Finch builds
 * CF for the Objective-C runtime (DEPLOYMENT_RUNTIME_SWIFT=0), as Apple
 * does; these fill in what that configuration expects from Apple's
 * internal build environment.
 */
#ifndef FINCH_CF_PREFIX_H
#define FINCH_CF_PREFIX_H

/* Cross-platform thread and environment helpers. swift-corelibs declares
 * them only for its Swift build, but the sources use them either way. */
#include "ForSwiftFoundationOnly.h"

/* Static CF objects (the allocators, kCFBooleanTrue/False, the CFNumber
 * constants, kCFNull) start
 * life with their ObjC class as isa (CFObjC.m), as in Apple's build;
 * swift-corelibs leaves it NULL outside its Swift build. */
#include "ForFoundationOnly.h"
#undef STATIC_CLASS_REF
#define STATIC_CLASS_REF(CLASSNAME) (&OBJC_CLASS_$_ ## CLASSNAME)
extern char OBJC_CLASS_$___NSCFType[], OBJC_CLASS_$___NSCFBoolean[], OBJC_CLASS_$___NSCFNumber[],
    OBJC_CLASS_$_NSNull[];

/* os_log SPI CF uses (OS_LOG_SUBSYSTEM_RUNTIME_ISSUES); Apple's internal
 * build environment has it in scope. */
#include <os/log_private.h>

/* Apple's internal name for the allocator's static runtime type ID. */
#define __kCFAllocatorTypeID_CONST _kCFRuntimeIDCFAllocator

#endif
