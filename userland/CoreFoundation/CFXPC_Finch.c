/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * CoreFoundation <-> XPC conversion (<CoreFoundation/CFXPCBridge.h>, private),
 * which Apple's CoreFoundation exports and IOKit's power management, among
 * others, uses. Property-list types map to their XPC counterparts:
 *
 *   CFString      string        CFNumber   int64 / double (floating types)
 *   CFBoolean     bool          CFData     data
 *   CFDate        date          CFUUID     uuid
 *   CFArray       array         CFDictionary  dictionary (string keys)
 *   CFNull        null
 *
 * The "message" forms carry the object in a dictionary under one key, the
 * one Apple's CoreFoundation uses, so either side can be Apple's.
 */

#include "CFInternal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <xpc/xpc.h>

#define MESSAGE_KEY "ECF19A18-7AA6-4141-B4DC-A2E5123B2B5C"

/* CFAbsoluteTime (seconds since 2001) <-> XPC date (nanoseconds since 1970). */
#define CF_EPOCH_NS (978307200LL * NSEC_PER_SEC)

CF_EXPORT xpc_object_t _CFXPCCreateXPCObjectFromCFObject(CFTypeRef object);
CF_EXPORT CFTypeRef _CFXPCCreateCFObjectFromXPCObject(xpc_object_t object);
CF_EXPORT xpc_object_t _CFXPCCreateXPCMessageWithCFObject(CFTypeRef object);
CF_EXPORT CFTypeRef _CFXPCCreateCFObjectFromXPCMessage(xpc_object_t message);

static void
add_entry(const void *key, const void *value, void *context)
{
    char buf[1024];
    char *name = buf;
    CFIndex size;
    if (CFGetTypeID(key) != CFStringGetTypeID()) return;   /* XPC keys are strings */
    size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(key), kCFStringEncodingUTF8) + 1;
    if (size > (CFIndex)sizeof(buf) && !(name = malloc((size_t)size))) return;
    if (CFStringGetCString(key, name, size, kCFStringEncodingUTF8)) {
        xpc_object_t v = _CFXPCCreateXPCObjectFromCFObject(value);
        if (v) {
            xpc_dictionary_set_value(context, name, v);
            xpc_release(v);
        }
    }
    if (name != buf) free(name);
}

xpc_object_t
_CFXPCCreateXPCObjectFromCFObject(CFTypeRef object)
{
    if (!object) return NULL;
    CFTypeID type = CFGetTypeID(object);
    if (type == CFStringGetTypeID()) {
        const char *fast = CFStringGetCStringPtr(object, kCFStringEncodingUTF8);
        if (fast) return xpc_string_create(fast);
        CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(object), kCFStringEncodingUTF8) + 1;
        char *s = malloc((size_t)size);
        xpc_object_t r = NULL;
        if (s && CFStringGetCString(object, s, size, kCFStringEncodingUTF8)) r = xpc_string_create(s);
        free(s);
        return r;
    }
    if (type == CFBooleanGetTypeID()) return xpc_bool_create(CFBooleanGetValue(object));
    if (type == CFNumberGetTypeID()) {
        if (CFNumberIsFloatType(object)) {
            double d = 0;
            CFNumberGetValue(object, kCFNumberDoubleType, &d);
            return xpc_double_create(d);
        }
        int64_t i = 0;
        CFNumberGetValue(object, kCFNumberSInt64Type, &i);
        return xpc_int64_create(i);
    }
    if (type == CFDataGetTypeID()) return xpc_data_create(CFDataGetBytePtr(object), (size_t)CFDataGetLength(object));
    if (type == CFDateGetTypeID()) {
        return xpc_date_create((int64_t)(CFDateGetAbsoluteTime(object) * NSEC_PER_SEC) + CF_EPOCH_NS);
    }
    if (type == CFUUIDGetTypeID()) {
        CFUUIDBytes b = CFUUIDGetUUIDBytes(object);
        return xpc_uuid_create((const unsigned char *)&b);
    }
    if (type == CFNullGetTypeID()) return xpc_null_create();
    if (type == CFArrayGetTypeID()) {
        xpc_object_t a = xpc_array_create(NULL, 0);
        for (CFIndex i = 0; i < CFArrayGetCount(object); i++) {
            xpc_object_t v = _CFXPCCreateXPCObjectFromCFObject(CFArrayGetValueAtIndex(object, i));
            if (v) {
                xpc_array_append_value(a, v);
                xpc_release(v);
            }
        }
        return a;
    }
    if (type == CFDictionaryGetTypeID()) {
        xpc_object_t d = xpc_dictionary_create(NULL, NULL, 0);
        CFDictionaryApplyFunction(object, add_entry, d);
        return d;
    }
    return NULL;
}

CFTypeRef
_CFXPCCreateCFObjectFromXPCObject(xpc_object_t object)
{
    if (!object) return NULL;
    xpc_type_t type = xpc_get_type(object);
    if (type == XPC_TYPE_STRING) {
        return CFStringCreateWithCString(kCFAllocatorDefault, xpc_string_get_string_ptr(object), kCFStringEncodingUTF8);
    }
    if (type == XPC_TYPE_BOOL) return CFRetain(xpc_bool_get_value(object) ? kCFBooleanTrue : kCFBooleanFalse);
    if (type == XPC_TYPE_INT64) {
        int64_t i = xpc_int64_get_value(object);
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &i);
    }
    if (type == XPC_TYPE_UINT64) {
        uint64_t u = xpc_uint64_get_value(object);
        if (u <= INT64_MAX) {
            int64_t i = (int64_t)u;
            return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &i);
        }
        double d = (double)u;
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &d);
    }
    if (type == XPC_TYPE_DOUBLE) {
        double d = xpc_double_get_value(object);
        return CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &d);
    }
    if (type == XPC_TYPE_DATA) {
        return CFDataCreate(kCFAllocatorDefault, xpc_data_get_bytes_ptr(object), (CFIndex)xpc_data_get_length(object));
    }
    if (type == XPC_TYPE_DATE) {
        return CFDateCreate(kCFAllocatorDefault, (double)(xpc_date_get_value(object) - CF_EPOCH_NS) / NSEC_PER_SEC);
    }
    if (type == XPC_TYPE_UUID) {
        CFUUIDBytes b;
        memcpy(&b, xpc_uuid_get_bytes(object), sizeof(b));
        return CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, b);
    }
    if (type == XPC_TYPE_NULL) return CFRetain(kCFNull);
    if (type == XPC_TYPE_ARRAY) {
        CFMutableArrayRef a = CFArrayCreateMutable(kCFAllocatorDefault, (CFIndex)xpc_array_get_count(object),
            &kCFTypeArrayCallBacks);
        xpc_array_apply(object, ^bool(size_t index, xpc_object_t value) {
            (void)index;
            CFTypeRef v = _CFXPCCreateCFObjectFromXPCObject(value);
            if (v) {
                CFArrayAppendValue(a, v);
                CFRelease(v);
            }
            return true;
        });
        return a;
    }
    if (type == XPC_TYPE_DICTIONARY) {
        CFMutableDictionaryRef d = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        xpc_dictionary_apply(object, ^bool(const char *key, xpc_object_t value) {
            CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
            CFTypeRef v = _CFXPCCreateCFObjectFromXPCObject(value);
            if (k && v) CFDictionarySetValue(d, k, v);
            if (k) CFRelease(k);
            if (v) CFRelease(v);
            return true;
        });
        return d;
    }
    return NULL;
}

xpc_object_t
_CFXPCCreateXPCMessageWithCFObject(CFTypeRef object)
{
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_object_t value = _CFXPCCreateXPCObjectFromCFObject(object);
    if (value) {
        xpc_dictionary_set_value(message, MESSAGE_KEY, value);
        xpc_release(value);
    }
    return message;
}

CFTypeRef
_CFXPCCreateCFObjectFromXPCMessage(xpc_object_t message)
{
    if (!message || xpc_get_type(message) != XPC_TYPE_DICTIONARY) return NULL;
    return _CFXPCCreateCFObjectFromXPCObject(xpc_dictionary_get_value(message, MESSAGE_KEY));
}
