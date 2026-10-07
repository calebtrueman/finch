/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCEC_H
#define FINCH_ABI_CCEC_H
#include "cczp.h"
#include "ccrng.h"
#include <stdbool.h>
/* Curve field, coefficient, generator and order; limb offsets measured on host. */
typedef const struct cczp *ccec_const_cp_t;
struct ccec_ctx { ccec_const_cp_t cp; uint64_t reserved; cc_unit data[]; };
const struct cczp *ccec_get_cp(size_t);
const struct cczp *ccec_cp_192(void);
const struct cczp *ccec_cp_224(void);
const struct cczp *ccec_cp_256(void);
const struct cczp *ccec_cp_384(void);
const struct cczp *ccec_cp_521(void);
int ccec_generate_key(ccec_const_cp_t,struct ccrng_state*,struct ccec_ctx*);
int ccec_export_pub(const struct ccec_ctx*,void*);
int ccec_x963_import_pub(ccec_const_cp_t,size_t,const void*,struct ccec_ctx*);
int ccec_sign(const struct ccec_ctx*,size_t,const void*,size_t*,void*,struct ccrng_state*);
int ccec_verify(const struct ccec_ctx*,size_t,const void*,size_t,const void*,bool*);
#endif
