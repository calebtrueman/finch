/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's Security.framework: shared internals. Public API is declared by
 * Apple's public SDK headers (<Security/Security.h>); everything here is
 * private to the framework (built with -fvisibility=hidden, exports.txt).
 */
#ifndef FINCH_SEC_INTERNAL_H
#define FINCH_SEC_INTERNAL_H

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFRuntime.h>
#include <Security/Security.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#define SEC_API __attribute__((visibility("default")))
#define SEC_HIDDEN __attribute__((visibility("hidden")))

/* CF type registration: returns the type ID, registering the class once. */
SEC_HIDDEN CFTypeID _SecRegisterClass(CFTypeID *slot, const CFRuntimeClass *cls);
SEC_HIDDEN CFTypeRef _SecCreateInstance(CFTypeID type, size_t size);   /* size includes CFRuntimeBase */

/* Errors */
SEC_HIDDEN CFErrorRef _SecCreateError(OSStatus status, CFStringRef description);
SEC_HIDDEN bool _SecSetError(CFErrorRef *error, OSStatus status, CFStringRef description);
SEC_HIDDEN CFStringRef _SecCopyErrorString(OSStatus status);   /* NULL if unknown */

/* Defines a CF class and its Sec...GetTypeID() function. */
#define SEC_DEFINE_TYPE(func, name, finalize, equal, hash)                                         \
	CFTypeID func(void)                                                                        \
	{                                                                                          \
		static CFTypeID id;                                                                \
		static const CFRuntimeClass cls = {0, name, NULL, NULL, finalize, equal, hash, NULL, NULL}; \
		return _SecRegisterClass(&id, &cls);                                               \
	}

SEC_HIDDEN CFDataRef _SecCertificateCopyNameDER(SecCertificateRef c, bool issuer);
SEC_HIDDEN CFDataRef _SecCertificateCopyPublicKeySHA1(SecCertificateRef c);

/* Keychain (SecKeychain.c) */
SEC_HIDDEN SecIdentityRef _SecIdentityCreate(SecCertificateRef cert, SecKeyRef key);

#endif
