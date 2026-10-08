/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <CoreFoundation/CFXPCBridge.h> (private): CoreFoundation <-> XPC
 * conversion. Finch's CoreFoundation implements these
 * (userland/CoreFoundation/CFXPC_Finch.c), with Apple's signatures.
 */
#ifndef __COREFOUNDATION_CFXPCBRIDGE__
#define __COREFOUNDATION_CFXPCBRIDGE__

#include <CoreFoundation/CoreFoundation.h>
#include <xpc/xpc.h>

CF_EXTERN_C_BEGIN

CF_EXPORT xpc_object_t _CFXPCCreateXPCObjectFromCFObject(CFTypeRef object);
CF_EXPORT CFTypeRef _CFXPCCreateCFObjectFromXPCObject(xpc_object_t object);
CF_EXPORT xpc_object_t _CFXPCCreateXPCMessageWithCFObject(CFTypeRef object);
CF_EXPORT CFTypeRef _CFXPCCreateCFObjectFromXPCMessage(xpc_object_t message);

CF_EXTERN_C_END

#endif
