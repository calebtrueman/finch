/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCDH_H
#define FINCH_ABI_CCDH_H
#include "cczp.h"
#include "ccrng.h"
struct ccdh_ctx { const struct cczp *gp; uint64_t reserved; cc_unit data[]; };
size_t ccdh_gp_size(size_t);
size_t ccdh_gp_n(const struct cczp*);
size_t ccdh_ccn_size(const struct cczp*);
size_t ccdh_gp_l(const struct cczp*);
cc_unit *ccdh_gp_prime(const struct cczp*);
cc_unit *ccdh_gp_g(const struct cczp*);
cc_unit *ccdh_gp_order(const struct cczp*);
size_t ccdh_gp_order_bitlen(const struct cczp*);
void ccdh_ctx_init(const struct cczp*,struct ccdh_ctx*);
struct ccdh_ctx *ccdh_ctx_public(struct ccdh_ctx*);
size_t ccdh_export_pub_size(const struct ccdh_ctx*);
void ccdh_export_pub(const struct ccdh_ctx*,void*);
int ccdh_import_pub(const struct cczp*,size_t,const void*,struct ccdh_ctx*);
int ccdh_import_priv(const struct cczp*,size_t,const void*,struct ccdh_ctx*);
int ccdh_import_full(const struct cczp*,size_t,const void*,size_t,const void*,struct ccdh_ctx*);
int ccdh_generate_key(const struct cczp*,struct ccrng_state*,struct ccdh_ctx*);
int ccdh_compute_shared_secret(const struct ccdh_ctx*,const struct ccdh_ctx*,size_t*,void*,struct ccrng_state*);
int ccdh_init_gp_from_bytes(struct cczp*,size_t,size_t,const void*,size_t,const void*,size_t,const void*,size_t);
#endif
