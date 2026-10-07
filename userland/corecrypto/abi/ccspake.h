/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCSPAKE_H
#define FINCH_ABI_CCSPAKE_H
#include "ccec.h"
#include "ccdigest.h"
#include "ccmode.h"
struct ccspake_cp { unsigned variant,reserved; const struct cczp *(*curve)(void); const cc_unit *m,*n; };
struct ccspake_ctx;
struct ccspake_mac { const struct ccdigest_info *(*digest)(void);const struct ccmode_cbc *(*cbc)(void);size_t key_size,tag_size;int(*derive)(const struct ccspake_ctx*,size_t,const void*,void*);int(*compute)(const struct ccspake_ctx*,size_t,const void*,size_t,const void*,size_t,void*); };
struct ccspake_ctx { const struct ccspake_cp *cp;const struct ccspake_mac *mac;struct ccrng_state *rng;unsigned char prover,pad[7];size_t context_size;unsigned char context[20],state,pad2[3];unsigned char digest[208],secret[64];cc_unit data[]; };
size_t ccspake_sizeof_w(const struct ccspake_cp*);
size_t ccspake_sizeof_point(const struct ccspake_cp*);
size_t ccspake_sizeof_ctx(const struct ccspake_cp*);
int ccspake_reduce_w(const struct ccspake_cp*,size_t,const void*,size_t,void*);
int ccspake_reduce_w_RFC9383(const struct ccspake_cp*,size_t,const void*,size_t,void*);
int ccspake_generate_L(const struct ccspake_cp*,size_t,const void*,size_t,void*,struct ccrng_state*);
int ccspake_prover_init(struct ccspake_ctx*,const struct ccspake_cp*,const struct ccspake_mac*,struct ccrng_state*,size_t,const void*,size_t,const void*,const void*);
int ccspake_verifier_init(struct ccspake_ctx*,const struct ccspake_cp*,const struct ccspake_mac*,struct ccrng_state*,size_t,const void*,size_t,const void*,size_t,const void*);
int ccspake_prover_initialize(struct ccspake_ctx*,const struct ccspake_cp*,const struct ccspake_mac*,struct ccrng_state*,size_t,const void*,size_t,const void*,size_t,const void*,size_t,const void*,const void*);
int ccspake_verifier_initialize(struct ccspake_ctx*,const struct ccspake_cp*,const struct ccspake_mac*,struct ccrng_state*,size_t,const void*,size_t,const void*,size_t,const void*,size_t,const void*,size_t,const void*);
int ccspake_kex_generate(struct ccspake_ctx*,size_t,void*);
int ccspake_kex_process(struct ccspake_ctx*,size_t,const void*);
int ccspake_mac_compute(struct ccspake_ctx*,size_t,void*);
int ccspake_mac_verify_and_get_session_key(struct ccspake_ctx*,size_t,const void*,size_t,void*);
int ccspake_get_session_key(struct ccspake_ctx*,size_t,void*);
#endif
