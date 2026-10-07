/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <stdlib.h>
#define EXPORT __attribute__((visibility("default")))
EXPORT __attribute__((noreturn)) void cc_abort(const char*message){(void)message;abort();}
EXPORT __attribute__((noreturn)) void cc_try_abort(const char*message){cc_abort(message);}
EXPORT void cc_try_abort_if(int condition,const char*message){if(condition)cc_abort(message);}
/* Finch obtains every system-random request directly from getentropy. There is
   no shared userspace random pool or lock to carry across fork. */
EXPORT void cc_atfork_prepare(void){}
EXPORT void cc_atfork_parent(void){}
EXPORT void cc_atfork_child(void){}
EXPORT const char *cc_impl_name(unsigned value){static const char*const names[62]={
 [1]="SHA256_LTC",[2]="SHA256_VNG_ARM",[3]="SHA256_VNG_ARM64_NEON",[4]="SHA256_VNG_INTEL_SUPPLEMENTAL_SSE3",[5]="SHA256_VNG_INTEL_AVX1",[6]="SHA256_VNG_INTEL_AVX2",[7]="SHA256_ARMV6M",
 [11]="AES_ECB_LTC",[12]="AES_ECB_ARM",[13]="AES_ECB_INTEL_OPT",[14]="AES_ECB_INTEL_AESNI",[15]="AES_ECB_SKG",[16]="AES_ECB_TRNG",
 [21]="AES_XTS_GENERIC",[22]="AES_XTS_ARM",[23]="AES_XTS_INTEL_OPT",[24]="AES_XTS_INTEL_AESNI",
 [31]="SHA1_LTC",[32]="SHA1_VNG_ARM",[33]="SHA1_VNG_INTEL_SUPPLEMENTAL_SSE3",[34]="SHA1_VNG_INTEL_AVX1",[35]="SHA1_VNG_INTEL_AVX2",
 [41]="SHA384_LTC",[42]="SHA384_VNG_ARM",[43]="SHA384_VNG_INTEL_SUPPLEMENTAL_SSE3",[44]="SHA384_VNG_INTEL_AVX1",[45]="SHA384_VNG_INTEL_AVX2",
 [51]="SHA512_LTC",[52]="SHA512_VNG_ARM",[53]="SHA512_VNG_INTEL_SUPPLEMENTAL_SSE3",[54]="SHA512_VNG_INTEL_AVX1",[55]="SHA512_VNG_INTEL_AVX2",[56]="SHA512_VNG_ARM_HW",[57]="SHA384_VNG_ARM_HW",[58]="SHA3_C",[59]="SHA3_VNG_INTEL",[60]="SHA3_VNG_ARM",[61]="SHA3_VNG_ARM_HW"};return value<62&&names[value]?names[value]:"UNKNOWN";}
