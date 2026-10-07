/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCRSA_H
#define FINCH_ABI_CCRSA_H
#include "cczp.h"
#include "ccdigest.h"
#include "ccrng.h"
#include <stdbool.h>
typedef struct cczp ccrsa_ctx;
static inline cc_unit *finch_rsa_e(const ccrsa_ctx*k){return (cc_unit*)((char*)k+32+16*k->n);}
static inline cc_unit *finch_rsa_d(const ccrsa_ctx*k){return (cc_unit*)((char*)k+32+24*k->n);}
static inline struct cczp *finch_rsa_p(const ccrsa_ctx*k){return (struct cczp*)((char*)k+32+32*k->n);}
static inline struct cczp *finch_rsa_q(const ccrsa_ctx*k){struct cczp*p=finch_rsa_p(k);return (struct cczp*)((char*)p+32+16*p->n);}
static inline cc_unit *finch_rsa_dp(const ccrsa_ctx*k){struct cczp*p=finch_rsa_p(k);return (cc_unit*)((char*)p+64+32*p->n);}
static inline cc_unit *finch_rsa_dq(const ccrsa_ctx*k){return finch_rsa_dp(k)+finch_rsa_p(k)->n;}
static inline cc_unit *finch_rsa_qinv(const ccrsa_ctx*k){return finch_rsa_dp(k)+2*finch_rsa_p(k)->n;}
void *ccrsa_ctx_public(void*);
struct cczp *ccrsa_ctx_private_zp(const ccrsa_ctx*);
size_t ccrsa_block_size(const ccrsa_ctx*);
size_t ccrsa_pubkeylength(const ccrsa_ctx*);
int ccrsa_init_pub(ccrsa_ctx*,const cc_unit*,const cc_unit*);
int ccrsa_make_pub(ccrsa_ctx*,size_t,const void*,size_t,const void*);
int ccrsa_pub_crypt(const ccrsa_ctx*,cc_unit*,const cc_unit*);
int ccrsa_priv_crypt(const ccrsa_ctx*,cc_unit*,const cc_unit*);
const unsigned char *ccder_decode_rsa_pub(ccrsa_ctx*,const unsigned char*,const unsigned char*);
const unsigned char *ccder_decode_rsa_pub_x509(ccrsa_ctx*,const unsigned char*,const unsigned char*);
const unsigned char *ccder_decode_rsa_priv(ccrsa_ctx*,const unsigned char*,const unsigned char*);
size_t ccder_encode_rsa_pub_size(const ccrsa_ctx*);
size_t ccder_encode_rsa_priv_size(const ccrsa_ctx*);
unsigned char *ccder_encode_rsa_pub(const ccrsa_ctx*,unsigned char*,unsigned char*);
unsigned char *ccder_encode_rsa_priv(const ccrsa_ctx*,unsigned char*,unsigned char*);
#endif
