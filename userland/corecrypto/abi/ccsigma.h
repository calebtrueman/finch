/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCSIGMA_H
#define FINCH_ABI_CCSIGMA_H
#include "ccec.h"
#include "ccdigest.h"
struct ccsigma_ctx;
struct ccsigma_session_ctx;
typedef int (*ccsigma_sign_fn)(
    void *, size_t, const void *, size_t *, void *, struct ccrng_state *);
struct ccsigma_info {
	ccec_const_cp_t kex_cp;
	struct ccec_ctx *(*kex)(struct ccsigma_ctx *);
	struct ccec_ctx *(*peer_kex)(struct ccsigma_ctx *);
	ccec_const_cp_t sign_cp;
	const struct ccdigest_info *di;
	size_t signature_size;
	struct ccec_ctx *(*sign_key)(struct ccsigma_ctx *);
	struct ccec_ctx *(*peer_sign_key)(struct ccsigma_ctx *);
	size_t key_count;
	const size_t *key_sizes;
	size_t keys_size;
	unsigned char *(*keys)(struct ccsigma_ctx *);
	int (*derive)(struct ccsigma_ctx *, size_t, const void *, size_t, const void *);
	size_t mac_size;
	int (*mac)(struct ccsigma_ctx *, size_t, const void *, size_t, const void *, void *);
	size_t mac_key_index[2];
	int (*mac_digest)(struct ccsigma_ctx *, unsigned, size_t, const void *, void *);
	size_t tag_size;
	int (*seal)(struct ccsigma_ctx *, size_t, const void *, size_t, const void *, size_t,
	    const void *, size_t, const void *, void *, void *);
	int (*open)(struct ccsigma_ctx *, size_t, const void *, size_t, const void *, size_t,
	    const void *, size_t, const void *, void *, const void *);
	void (*next_iv)(size_t, void *);
	void (*clear)(struct ccsigma_ctx *);
};
struct ccsigma_ctx {
	const struct ccsigma_info *info;
	unsigned role, reserved;
	ccsigma_sign_fn sign;
	void *sign_context;
	unsigned char data[];
};
struct ccsigma_session_info {
	const struct ccdigest_info *di;
	size_t tag_size;
	int (*seal)(struct ccsigma_session_ctx *, size_t, const void *, size_t, const void *,
	    void *, void *);
	int (*open)(struct ccsigma_session_ctx *, size_t, const void *, size_t, const void *,
	    void *, const void *, uint64_t);
	uint64_t (*get_sequence)(struct ccsigma_session_ctx *);
	void (*set_sequence)(struct ccsigma_session_ctx *, uint64_t);
	void (*advance)(struct ccsigma_session_ctx *);
	int (*init)(unsigned, size_t, const void *, size_t, const void *,
	    struct ccsigma_session_ctx *, struct ccsigma_session_ctx *);
	int (*import)(struct ccsigma_session_ctx *, const void *);
	size_t (*serialized_size)(void);
	int (*export)(struct ccsigma_session_ctx *, void *);
	void (*clear)(struct ccsigma_session_ctx *);
};
struct ccsigma_session_ctx {
	const struct ccsigma_session_info *info;
	unsigned direction, reserved;
	unsigned char key[32], iv[12], pad[4];
	uint64_t sequence;
};
const struct ccsigma_info *ccsigma_mfi_info(void);
const struct ccsigma_info *ccsigma_mfi_nvm_info(void);
const struct ccsigma_info *ccsigma_exclave_pairing_info(void);
const struct ccsigma_session_info *ccsigma_exclave_pairing_session_info(void);
int ccsigma_init(const struct ccsigma_info *, struct ccsigma_ctx *, unsigned, struct ccrng_state *);
int ccsigma_set_signing_function(struct ccsigma_ctx *, ccsigma_sign_fn, void *);
int ccsigma_import_signing_key(struct ccsigma_ctx *, size_t, const void *);
int ccsigma_import_peer_verification_key(struct ccsigma_ctx *, size_t, const void *);
int ccsigma_export_key_share(struct ccsigma_ctx *, size_t *, void *);
int ccsigma_import_peer_key_share(struct ccsigma_ctx *, size_t, const void *);
unsigned ccsigma_peer_role(struct ccsigma_ctx *);
struct ccec_ctx *ccsigma_kex_init_ctx(struct ccsigma_ctx *);
struct ccec_ctx *ccsigma_kex_resp_ctx(struct ccsigma_ctx *);
int ccsigma_derive_session_keys(struct ccsigma_ctx *, size_t, const void *, struct ccrng_state *);
int ccsigma_compute_mac(struct ccsigma_ctx *, size_t, size_t, const void *, void *);
int ccsigma_sign(struct ccsigma_ctx *, void *, size_t, const void *, struct ccrng_state *);
int ccsigma_verify(struct ccsigma_ctx *, const void *, size_t, const void *);
int ccsigma_seal(struct ccsigma_ctx *, size_t, size_t, size_t, const void *, size_t, const void *,
    void *, void *);
int ccsigma_open(struct ccsigma_ctx *, size_t, size_t, size_t, const void *, size_t, const void *,
    void *, const void *);
int ccsigma_clear_key(struct ccsigma_ctx *, size_t);
void ccsigma_clear(struct ccsigma_ctx *);
int ccsigma_session_init(struct ccsigma_ctx *, size_t, size_t, const void *,
    const struct ccsigma_session_info *, struct ccsigma_session_ctx *,
    struct ccsigma_session_ctx *);
int ccsigma_session_seal(struct ccsigma_session_ctx *, size_t, const void *, size_t, const void *,
    void *, void *, uint64_t *);
int ccsigma_session_open(struct ccsigma_session_ctx *, size_t, const void *, size_t, const void *,
    void *, const void *, uint64_t);
int ccsigma_session_export(struct ccsigma_session_ctx *, size_t, void *);
int ccsigma_session_import(
    const struct ccsigma_session_info *, struct ccsigma_session_ctx *, size_t, const void *);
void ccsigma_session_clear(struct ccsigma_session_ctx *);
#endif
