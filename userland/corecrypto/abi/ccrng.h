/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCRNG_H
#define FINCH_ABI_CCRNG_H
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
struct ccrng_state { int (*generate)(struct ccrng_state *, size_t, void *); };
struct ccrng_sequence_state { struct ccrng_state rng; const unsigned char *bytes; size_t length; };
struct ccdrbg_info {
    size_t size;
    int (*init)(const struct ccdrbg_info *, void *, size_t, const void *, size_t, const void *, size_t, const void *);
    int (*reseed)(void *, size_t, const void *, size_t, const void *);
    int (*generate)(void *, size_t, void *, size_t, const void *);
    void (*done)(void *);
    const void *custom;
    bool (*must_reseed)(void *);
};
struct ccrng_drbg_state { struct ccrng_state rng; const struct ccdrbg_info *info; void *state; };
#endif
