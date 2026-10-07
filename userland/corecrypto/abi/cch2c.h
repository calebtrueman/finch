/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCH2C_H
#define FINCH_ABI_CCH2C_H
#include "ccec.h"
#include "ccdigest.h"
struct cch2c_info {
 const char*name;uint32_t l,z;
 ccec_const_cp_t(*cp)(void);const struct ccdigest_info*(*di)(void);
 int(*hash)(void*,const struct cch2c_info*,size_t,const void*,size_t,const void*,unsigned,cc_unit*);
 int(*map)(void*,const struct cch2c_info*,const cc_unit*,struct ccec_ctx*);
 int(*clear)(const struct cch2c_info*,struct ccec_ctx*);
 int(*encode)(void*,const struct cch2c_info*,size_t,const void*,size_t,const void*,struct ccec_ctx*);
};
extern const struct cch2c_info cch2c_p256_sha256_sswu_ro_info;
extern const struct cch2c_info cch2c_p384_sha512_sswu_ro_info;
extern const struct cch2c_info cch2c_p521_sha512_sswu_ro_info;
extern const struct cch2c_info cch2c_p256_sha256_sae_compat_info;
extern const struct cch2c_info cch2c_p384_sha384_sae_compat_info;
int cch2c(const struct cch2c_info*,size_t,const void*,size_t,const void*,struct ccec_ctx*);
const char*cch2c_name(const struct cch2c_info*);
#endif
