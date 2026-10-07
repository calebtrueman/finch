/* SPDX-License-Identifier: MIT OR Apache-2.0
 * The digest fields read by macOS callers. Measured from the local
 * corecrypto library and checked by digest-abi-compare.c.
 */
#ifndef FINCH_ABI_CCDIGEST_H
#define FINCH_ABI_CCDIGEST_H
#include <stddef.h>
#include <stdint.h>

struct ccdigest_info {
    size_t output_size, state_size, block_size, oid_size;
    const unsigned char *oid;
    const void *initial_state;
    void (*compress)(void *, size_t, const void *);
    void (*final)(const struct ccdigest_info *, void *, unsigned char *);
    uint64_t implementation;
    void (*compress_parallel)(void *, size_t, const void *, void *, size_t, const void *);
};

/* Bits in completed blocks; chaining state; pending bytes; pending count. */
static inline size_t ccdigest_di_size(const struct ccdigest_info *di)
{ return 12 + di->state_size + di->block_size; }
static inline unsigned char *ccdigest_state_u8(const struct ccdigest_info *di, void *ctx)
{ (void)di; return (unsigned char *)ctx + 8; }
static inline unsigned char *ccdigest_data(const struct ccdigest_info *di, void *ctx)
{ return ccdigest_state_u8(di, ctx) + di->state_size; }

void ccdigest_init(const struct ccdigest_info *, void *);
void ccdigest_update(const struct ccdigest_info *, void *, size_t, const void *);
void ccdigest_parallel(const struct ccdigest_info *, size_t, const void *, void *, const void *, void *);
void ccdigest(const struct ccdigest_info *, size_t, const void *, void *);
const struct ccdigest_info *ccsha1_di(void);
const struct ccdigest_info *ccsha224_di(void);
const struct ccdigest_info *ccsha256_di(void);
const struct ccdigest_info *ccsha384_di(void);
const struct ccdigest_info *ccsha512_di(void);
#endif
