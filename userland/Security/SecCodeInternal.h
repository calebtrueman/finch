/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Code signing internals shared by SecCode.c and SecRequirement.c. */
#ifndef FINCH_SEC_CODE_INTERNAL_H
#define FINCH_SEC_CODE_INTERNAL_H

#include "SecInternal.h"

/* What a requirement is evaluated against. */
typedef struct {
	CFStringRef identifier;
	CFArrayRef cdhashes;        /* CFData, one per code directory */
	CFDictionaryRef infoPlist;
	CFDictionaryRef entitlements;
	CFArrayRef certificates;    /* leaf first; NULL for ad-hoc code */
	uint32_t platform;
} SecCodeContext;

SEC_HIDDEN SecRequirementRef _SecRequirementCreate(CFDataRef blob);
SEC_HIDDEN CFDataRef _SecRequirementGetData(SecRequirementRef r);
SEC_HIDDEN bool _SecRequirementEvaluate(SecRequirementRef req, const SecCodeContext *ctx);
SEC_HIDDEN CFStringRef _SecRequirementsCopyText(const uint8_t *p, size_t n);
SEC_HIDDEN SecRequirementRef _SecRequirementsCopyType(const uint8_t *p, size_t n, uint32_t type);

SEC_HIDDEN CFDataRef _SecCodeCopySHA1(CFDataRef data);
SEC_HIDDEN CFTypeRef _SecCodeCopyCertificateField(SecCertificateRef cert, uint32_t op, const uint8_t *key, size_t keyLength);

/* The executable and entitlements of a running process (SecTask). */
SEC_HIDDEN CFStringRef _SecCodeCopyIdentifierForPID(pid_t pid);
SEC_HIDDEN CFDictionaryRef _SecCodeCopyEntitlementsForPID(pid_t pid);

#endif
