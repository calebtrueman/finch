/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCN_H
#define FINCH_ABI_CCN_H
#include <stddef.h>
#include <stdint.h>
typedef uint64_t cc_unit;
uint64_t ccn_add(size_t, cc_unit *, const cc_unit *, const cc_unit *);
uint64_t ccn_add1(size_t, cc_unit *, const cc_unit *, cc_unit);
uint64_t ccn_sub(size_t, cc_unit *, const cc_unit *, const cc_unit *);
size_t ccn_bitlen(size_t, const cc_unit *);
int ccn_cmp(size_t, const cc_unit *, const cc_unit *);
int ccn_cmpn(size_t, const cc_unit *, size_t, const cc_unit *);
int ccn_read_uint(size_t, cc_unit *, size_t, const void *);
size_t ccn_write_uint_size(size_t, const cc_unit *);
size_t ccn_write_int_size(size_t, const cc_unit *);
void ccn_write_uint(size_t, const cc_unit *, size_t, void *);
void ccn_write_int(size_t, const cc_unit *, size_t, void *);
int ccn_write_uint_padded_ct(size_t, const cc_unit *, size_t, void *);
size_t ccn_write_uint_padded(size_t, const cc_unit *, size_t, void *);
void ccn_zero(size_t, cc_unit *);
void ccn_seti(size_t, cc_unit *, cc_unit);
void ccn_set_bit(cc_unit *, size_t, cc_unit);
void ccn_swap(size_t, cc_unit *);
void ccn_xor(size_t, cc_unit *, const cc_unit *, const cc_unit *);
void ccn_print(size_t, const cc_unit *);
void ccn_lprint(size_t, const char *, const cc_unit *);
#endif
