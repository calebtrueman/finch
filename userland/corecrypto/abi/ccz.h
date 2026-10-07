/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCZ_H
#define FINCH_ABI_CCZ_H
#include "ccn.h"
#include <stdbool.h>
struct ccz_class {
    void *context;
    void *(*allocate)(void *,size_t);
    void *(*reallocate)(void *,size_t,void *,size_t);
    void (*deallocate)(void *,size_t,void *);
};
struct ccz {
    size_t n;
    const struct ccz_class *isa;
    int32_t capacity;
    uint32_t reserved;
    cc_unit *units;
};
size_t ccz_size(void);
void ccz_init(const struct ccz_class *,struct ccz *);
void ccz_free(struct ccz *);
size_t ccz_n(const struct ccz *);
size_t ccz_capacity(const struct ccz *);
int ccz_sign(const struct ccz *);
void ccz_set_n(struct ccz *,size_t);
void ccz_set_sign(struct ccz *,int);
void ccz_set_capacity(struct ccz *,size_t);
void ccz_set(struct ccz *,const struct ccz *);
void ccz_seti(struct ccz *,uint64_t);
void ccz_zero(struct ccz *);
void ccz_neg(struct ccz *);
size_t ccz_bitlen(const struct ccz *);
size_t ccz_trailing_zeros(const struct ccz *);
bool ccz_is_zero(const struct ccz *);
bool ccz_is_one(const struct ccz *);
bool ccz_is_negative(const struct ccz *);
int ccz_bit(const struct ccz *,size_t);
void ccz_set_bit(struct ccz *,size_t,int);
int ccz_cmp(const struct ccz *,const struct ccz *);
int ccz_cmpi(const struct ccz *,uint32_t);
void ccz_read_uint(struct ccz *,size_t,const void *);
size_t ccz_write_uint_size(const struct ccz *);
size_t ccz_write_int_size(const struct ccz *);
void ccz_write_uint(const struct ccz *,size_t,void *);
void ccz_write_int(const struct ccz *,size_t,void *);
void ccz_add(struct ccz*,const struct ccz*,const struct ccz*);
void ccz_sub(struct ccz*,const struct ccz*,const struct ccz*);
void ccz_mul(struct ccz*,const struct ccz*,const struct ccz*);
void ccz_addi(struct ccz*,const struct ccz*,uint32_t);
void ccz_subi(struct ccz*,const struct ccz*,uint32_t);
void ccz_muli(struct ccz*,const struct ccz*,uint32_t);
void ccz_lsl(struct ccz*,const struct ccz*,size_t);
void ccz_lsr(struct ccz*,const struct ccz*,size_t);
void ccz_divmod(struct ccz*,struct ccz*,const struct ccz*,const struct ccz*);
void ccz_mod(struct ccz*,const struct ccz*,const struct ccz*);
void ccz_mulmod(struct ccz*,const struct ccz*,const struct ccz*,const struct ccz*);
int ccz_expmod(struct ccz*,const struct ccz*,const struct ccz*,const struct ccz*);
bool ccz_is_prime(const struct ccz*,unsigned);
struct ccrng_state;
int ccz_random_bits(struct ccz*,size_t,struct ccrng_state*);
int ccz_read_radix(struct ccz*,size_t,const char*,unsigned);
size_t ccz_write_radix_size(const struct ccz*,unsigned);
int ccz_write_radix(const struct ccz*,size_t,char*,unsigned);
#endif
