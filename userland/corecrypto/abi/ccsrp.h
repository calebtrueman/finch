/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCSRP_H
#define FINCH_ABI_CCSRP_H
#include "ccdh.h"
#include "ccdigest.h"
#include <stdbool.h>
struct ccsrp_ctx { const struct ccdigest_info *di; const struct cczp *gp; struct ccrng_state *rng; uint32_t flags,reserved; cc_unit data[]; };
int ccsrp_ctx_init_with_size_option(struct ccsrp_ctx*,size_t,const struct ccdigest_info*,const struct cczp*,unsigned,struct ccrng_state*);
int ccsrp_ctx_init_option(struct ccsrp_ctx*,const struct ccdigest_info*,const struct cczp*,unsigned,struct ccrng_state*);
void ccsrp_ctx_init(struct ccsrp_ctx*,const struct ccdigest_info*,const struct cczp*);
size_t ccsrp_sizeof_session_key(const struct ccdigest_info*,unsigned);
size_t ccsrp_get_session_key_length(const struct ccsrp_ctx*);
const void *ccsrp_get_session_key(const struct ccsrp_ctx*,size_t*);
int ccsrp_generate_verifier(struct ccsrp_ctx*,const char*,size_t,const void*,size_t,const void*,void*);
int ccsrp_generate_salt_and_verification(struct ccsrp_ctx*,struct ccrng_state*,const char*,size_t,const void*,size_t,void*,void*);
int ccsrp_client_start_authentication(struct ccsrp_ctx*,struct ccrng_state*,void*);
int ccsrp_client_process_challenge(struct ccsrp_ctx*,const char*,size_t,const void*,size_t,const void*,const void*,void*);
int ccsrp_server_generate_public_key(struct ccsrp_ctx*,struct ccrng_state*,const void*,void*);
int ccsrp_server_compute_session(struct ccsrp_ctx*,const char*,size_t,const void*,const void*);
int ccsrp_server_start_authentication(struct ccsrp_ctx*,struct ccrng_state*,const char*,size_t,const void*,const void*,const void*,void*);
bool ccsrp_client_verify_session(struct ccsrp_ctx*,const void*);
bool ccsrp_server_verify_session(struct ccsrp_ctx*,const void*,void*);
#endif
