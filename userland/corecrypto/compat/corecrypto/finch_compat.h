/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Source-facing names used by the open-source CommonCrypto clients.
 * Storage layouts are Finch's measured and tested shared-library layouts.
 */
#ifndef FINCH_COMMONCRYPTO_COMPAT_H
#define FINCH_COMMONCRYPTO_COMPAT_H
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include "finch_modes.h"
#include "../../abi/ccdigest.h"
#include "../../abi/cchmac.h"
#include "../../abi/ccder.h"
#include "../../abi/ccn.h"
#include "finch_ccz.h"
#include "../../abi/cczp.h"
#include "../../abi/ccrsa.h"
#include "../../abi/ccec.h"
#include "../../abi/ccdh.h"
#include "../../abi/ccrng.h"
#include "../../abi/legacy_ciphers.h"
#include "../../abi/chacha.h"
#include "../../abi/cch2c.h"
typedef size_t cc_size;
typedef const unsigned char *ccoid_t;
#define CC_MIN(a, b) ((a) < (b) ? (a) : (b))
#define CC_MAX(a, b) ((a) > (b) ? (a) : (b))
#define CC_STORE32_BE(v, p)                                                                        \
	do {                                                                                       \
		uint32_t finch_v = __builtin_bswap32(v);                                           \
		memcpy(p, &finch_v, 4);                                                            \
	} while (0)
#define CC_STORE64_BE(v, p)                                                                        \
	do {                                                                                       \
		uint64_t finch_v = __builtin_bswap64(v);                                           \
		memcpy(p, &finch_v, 8);                                                            \
	} while (0)
#define CCMODE_INVALID_CALL_SEQUENCE -1
#define CCERR_OK 0
#define CCERR_PARAMETER -7
#define CCERR_INVALID_SIGNATURE -146
#define CCERR_VALID_SIGNATURE 0
#define CCERR_MEMORY_ALLOC -13
#define CCERR_INTEGRITY -2
#define CCERR_CALL_SEQUENCE -1
#define CCN_UNIT_SIZE 8
#define CCN_UNIT_BITS 64
#define CC_ENSURE_DIT_ENABLED
#define cc_assert(x) ((void)0)
#define cc_memcpy memcpy
#define cc_memmove memmove
#define cc_memset memset
#define ccn_nof(bits) (((bits) + 63) / 64)
#define ccn_nof_size(bytes) (((bytes) + 7) / 8)
#define ccn_sizeof(bits) (ccn_nof(bits) * 8)
#define ccn_sizeof_n(n) ((n) * 8)
#define ccn_bitsof_n(n) ((n) * 64)
#define ccn_bitsof_size(bytes) ((bytes) * 8)
#define cc_ctx_n(type, size) (((size) + sizeof(type) - 1) / sizeof(type))
#define cc_absolute_time mach_absolute_time
struct ccdigest_ctx {
	unsigned char bytes[1];
};
struct ccdigest_state {
	unsigned char bytes[1];
};
typedef void *ccdigest_ctx_t;
typedef void *ccdigest_state_t;
#define ccdigest_di_decl(di, name) _Alignas(16) unsigned char name[ccdigest_di_size(di)]
#define ccdigest_nbits(di, c) (*(uint64_t *)(c))
#define ccdigest_num(di, c)                                                                        \
	(*(uint32_t *)((unsigned char *)(c) + 8 + (di)->state_size + (di)->block_size))
#define ccdigest_state(di, c) ccdigest_state_u8(di, c)
#define ccdigest_data(di, c) ccdigest_data_compat(di, c)
static inline unsigned char *ccdigest_data_compat(const struct ccdigest_info *d, void *c)
{
	return (unsigned char *)c + 8 + d->state_size;
}
static inline void ccdigest_final(const struct ccdigest_info *d, void *c, void *out)
{
	d->final(d, c, out);
}
typedef unsigned char cchmac_ctx;
#define cchmac_ctx_decl(state, block, name)                                                        \
	_Alignas(16) unsigned char name[12 + 2 * (state) + (block)]
#define ccmode_cfb ccmode_stream
#define ccmode_cfb8 ccmode_stream
#define ccmode_ofb ccmode_stream
typedef unsigned char ccecb_ctx, cccbc_ctx, cccbc_iv, ccctr_ctx, cccfb_ctx, cccfb8_ctx, ccgcm_ctx,
    ccxts_ctx, ccccm_ctx, ccccm_nonce, ccrc4_ctx;
typedef void ccofb_ctx;
struct _ccmode_ccm_nonce {
	unsigned char bytes[88];
	size_t mac_size;
};
#define ccecb_ctx_decl(size, name) _Alignas(16) unsigned char name[size]
#define ccecb_ctx_clear(size, name) cc_clear(size, name)
#define ccxts_tweak_decl(size, name) _Alignas(16) unsigned char name[size]
typedef void *cccmac_ctx_t;
#define cccmac_ctx_size(cbc) (80 + (cbc)->size + (cbc)->block_size)
#define cccmac_cbc(c) (*(const struct ccmode_cbc **)((unsigned char *)(c) + 64))
typedef struct ccec_ctx *ccec_full_ctx_t, *ccec_pub_ctx_t;
#define ccec_ctx_cp(c) ((c)->cp)
#define ccec_ctx_init(group, c) ((c)->cp = (group))
#define ccec_ctx_k(c) ((c)->data + 3 * (c)->cp->n)
#define ccec_ctx_public(c) (c)
#define ccec_ccn_size(cp) ((cp)->n * 8)
#define ccec_cp_prime_bitlen(cp) ((cp)->bitlen)
#define ccec_full_ctx_size(bytes) (16 + 4 * ((((bytes) + 7) / 8) * 8))
#define ccec_pub_ctx_size(bytes) (16 + 3 * ((((bytes) + 7) / 8) * 8))
#define ccec_full_ctx_decl_cp(cp, name)                                                            \
	_Alignas(16) unsigned char name##_storage[16 + 32 * (cp)->n];                              \
	ccec_full_ctx_t name = (void *)name##_storage
#define ccec_pub_ctx_decl_cp(cp, name)                                                             \
	_Alignas(16) unsigned char name##_storage[16 + 24 * (cp)->n];                              \
	ccec_pub_ctx_t name = (void *)name##_storage
#define ccec_full_ctx_clear_cp(cp, c) cc_clear(16 + 32 * (cp)->n, c)
#define ccec_pub_ctx_clear_cp(cp, c) cc_clear(16 + 24 * (cp)->n, c)
typedef const struct cczp *ccdh_const_gp_t;
typedef struct ccdh_ctx *ccdh_full_ctx_t, *ccdh_pub_ctx_t;
#define ccdh_ctx_gp(c) ((c)->gp)
#define ccdh_gp_prime_bitlen(g) ((g)->bitlen)
#define ccdh_full_ctx_size(bytes) (16 + 2 * ((((bytes) + 7) / 8) * 8))
#define ccdh_pub_ctx_decl_gp(g, name)                                                              \
	_Alignas(16) unsigned char name##_storage[16 + 8 * (g)->n];                                \
	ccdh_pub_ctx_t name = (void *)name##_storage
#define ccrsa_full_ctx cczp
typedef ccrsa_ctx *ccrsa_full_ctx_t, *ccrsa_pub_ctx_t;
#define ccrsa_ctx_n(c) (((ccrsa_ctx *)(c))->n)
#define CCZP_N(c) (((struct cczp *)(c))->n)
#define ccrsa_ctx_m(c) ((c)->data)
#define ccrsa_ctx_zm(c) (c)
#define ccrsa_ctx_e(c) finch_rsa_e(c)
#define ccrsa_ctx_private_zq(c) finch_rsa_q(c)
#define ccrsa_ctx_private_dp(c) finch_rsa_dp(c)
#define ccrsa_ctx_private_dq(c) finch_rsa_dq(c)
#define ccrsa_ctx_private_qinv(c) finch_rsa_qinv(c)
#define ccrsa_full_ctx_size(bytes)                                                                 \
	(96 + 32 * ccn_nof_size(bytes) + 56 * ((ccn_nof_size(bytes) + 1) / 2 + 1))
struct ccckg_ctx;
struct ccckg2_params;
struct cch2c_info;
typedef struct ccckg_ctx *ccckg_ctx_t, *ccckg2_ctx_t;
typedef const struct ccckg2_params *ccckg2_params_t;
#define CC_UNUSED __attribute__((unused))
#define CC_BITLEN_TO_BYTELEN(bits) (((bits) + 7) / 8)
#define CCAES_BLOCK_SIZE 16
#define CCAES_KEY_SIZE_128 16
#define CCAES_KEY_SIZE_192 24
#define CCAES_KEY_SIZE_256 32
#define CCCHACHA20_KEY_NBYTES 32
#define CCCHACHA20_NONCE_NBYTES 12
#define CCPOLY1305_TAG_NBYTES 16
#define CCWRAP_SEMIBLOCK 8
#define require(test, label)                                                                       \
	do {                                                                                       \
		if (!(test))                                                                       \
			goto label;                                                                \
	} while (0)
#define require_action(test, label, action)                                                        \
	do {                                                                                       \
		if (!(test)) {                                                                     \
			action;                                                                    \
			goto label;                                                                \
		}                                                                                  \
	} while (0)
#define CC_LOAD32_BE(v, p)                                                                         \
	do {                                                                                       \
		memcpy(&(v), p, 4);                                                                \
		(v) = __builtin_bswap32(v);                                                        \
	} while (0)
extern const unsigned char CCRSA_PKCS1_FAULT_CANARY[16], CCRSA_PSS_FAULT_CANARY[16];
extern const struct ccdigest_info ccmd2_ltc_di, ccmd4_ltc_di, ccrmd160_ltc_di;
#define ccmd2_di ccmd2_ltc_di
#define ccmd4_di ccmd4_ltc_di
#define ccrmd160_di ccrmd160_ltc_di
extern const struct ccrc4_info ccrc4_eay;
static inline int ccrng_generate(struct ccrng_state *r, size_t n, void *out)
{
	return r->generate(r, n, out);
}
static inline size_t ccec_x963_export_size_cp(bool priv, ccec_const_cp_t cp)
{
	return 1 + (priv ? 3 : 2) * ((cp->bitlen + 7) / 8);
}
static inline size_t ccec_x963_export_size(bool priv, const struct ccec_ctx *c)
{
	return ccec_x963_export_size_cp(priv, c->cp);
}
static inline size_t ccec_compact_export_size(bool priv, const struct ccec_ctx *c)
{
	return (priv ? 2 : 1) * ((c->cp->bitlen + 7) / 8);
}
#include "finch_decls.h"
typedef struct ccz ccz;
#define ccz_size(...) ccz_size()
#endif
