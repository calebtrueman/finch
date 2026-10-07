/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCXOF_H
#define FINCH_ABI_CCXOF_H
#include <stddef.h>
struct ccxof_info {
    size_t state_size, block_size;
    void (*init)(const struct ccxof_info *, void *);
    void (*absorb)(const struct ccxof_info *, void *, size_t, const void *);
    void (*absorb_last)(const struct ccxof_info *, void *, size_t, const void *);
    void (*squeeze)(const struct ccxof_info *, void *, size_t, void *);
};
const struct ccxof_info *ccshake128_xi(void);
const struct ccxof_info *ccshake256_xi(void);
void ccxof_init(const struct ccxof_info *, void *);
void ccxof_absorb(const struct ccxof_info *, void *, size_t, const void *);
void ccxof_squeeze(const struct ccxof_info *, void *, size_t, void *);
#endif
