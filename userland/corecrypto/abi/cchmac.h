/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCHMAC_H
#define FINCH_ABI_CCHMAC_H
#include "ccdigest.h"
static inline size_t cchmac_di_size(const struct ccdigest_info *di)
{ return ((ccdigest_di_size(di) + 7) & ~(size_t)7) + di->state_size; }
void cchmac_init(const struct ccdigest_info *, void *, size_t, const void *);
void cchmac_update(const struct ccdigest_info *, void *, size_t, const void *);
void cchmac_final(const struct ccdigest_info *, void *, void *);
void cchmac(const struct ccdigest_info *, size_t, const void *, size_t, const void *, void *);
#endif
