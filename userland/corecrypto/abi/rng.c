/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccrng.h"
#include <errno.h>
#include <string.h>
#include <sys/random.h>
#define EXPORT __attribute__((visibility("default")))
static void wipe(void *p, size_t n) { volatile unsigned char *b=p; while(n--) *b++=0; }
static int system_generate(struct ccrng_state *rng, size_t n, void *output)
{
    (void)rng;
    unsigned char *out=output; size_t left=n;
    while(left) {
        size_t take=left<256?left:256;
        if(getentropy(out,take)) {
            if(errno==EINTR) continue;
            wipe(output,n); return -1;
        }
        out+=take;left-=take;
    }
    return 0;
}
static struct ccrng_state system_rng={system_generate};

/*
 * OpenSSL seeds itself through CommonCrypto on Apple platforms, but CommonCrypto
 * is built on this library. This hidden definition satisfies OpenSSL's reference
 * inside libcorecrypto with the same kernel source; it is not exported, so it
 * never interposes on CommonCrypto's public function.
 */
int CCRandomGenerateBytes(void *bytes, size_t count);
int CCRandomGenerateBytes(void *bytes, size_t count)
{
    return system_generate(NULL, count, bytes) ? -4307 /* kCCRNGFailure */ : 0;
}
EXPORT struct ccrng_state *ccrng_prng(int *error) { if(error)*error=0;return &system_rng; }
EXPORT struct ccrng_state *ccrng(int *error) { return ccrng_prng(error); }
EXPORT struct ccrng_state *ccrng_trng(int *error) { if(error)*error=-173;return NULL; }
EXPORT int ccrng_system_init(struct ccrng_state *rng) { rng->generate=system_generate;return 0; }
EXPORT void ccrng_system_done(struct ccrng_state *rng) { (void)rng; }
EXPORT int ccrng_uniform(struct ccrng_state *rng,uint64_t bound,uint64_t *out)
{
    if(!bound) { *out=0;return -7; }
    uint64_t mask=UINT64_MAX >> __builtin_clzll(bound);
    for(;;) {
        int r=rng->generate(rng,sizeof(*out),out);
        if(r) { *out=0;return r; }
        *out &= mask;
        if(*out<bound)return 0;
    }
}
static int sequence_generate(struct ccrng_state *rng,size_t n,void *output)
{
    struct ccrng_sequence_state *s=(void*)rng;
    if(!s->length)return -5;
    unsigned char*out=output;
    for(size_t i=0;i<n;i++)out[i]=s->bytes[i%s->length];
    return 0;
}
EXPORT int ccrng_sequence_init(struct ccrng_sequence_state *rng,size_t n,const void *bytes)
{ rng->rng.generate=sequence_generate;rng->bytes=bytes;rng->length=n;return 0; }
EXPORT size_t ccdrbg_context_size(const struct ccdrbg_info *info) { return info->size; }
EXPORT int ccdrbg_init(const struct ccdrbg_info *info,void *state,size_t entropy_size,const void *entropy,
    size_t nonce_size,const void *nonce,size_t personal_size,const void *personal)
{ return info->init(info,state,entropy_size,entropy,nonce_size,nonce,personal_size,personal); }
EXPORT int ccdrbg_reseed(const struct ccdrbg_info *info,void *state,size_t n,const void *entropy,size_t extra_size,const void *extra)
{ return info->reseed(state,n,entropy,extra_size,extra); }
EXPORT int ccdrbg_generate(const struct ccdrbg_info *info,void *state,size_t n,void *out,size_t extra_size,const void *extra)
{ return info->generate(state,n,out,extra_size,extra); }
EXPORT void ccdrbg_done(const struct ccdrbg_info *info,void *state) { info->done(state); }
static int drbg_generate(struct ccrng_state *rng,size_t n,void *out)
{
    struct ccrng_drbg_state *r=(void*)rng;
    return r->info->generate(r->state,n,out,0,NULL);
}
EXPORT int ccrng_drbg_init_withdrbg(struct ccrng_drbg_state *rng,const struct ccdrbg_info *info,void *state)
{ rng->rng.generate=drbg_generate;rng->info=info;rng->state=state;return 0; }
EXPORT int ccrng_drbg_init(struct ccrng_drbg_state *rng,const struct ccdrbg_info *info,void *state,size_t n,const void *entropy)
{
    static const char personal[]="corecrypto drbg based rng";
    int r=info->init(info,state,n,entropy,n,entropy,sizeof(personal),personal);
    if(!r)ccrng_drbg_init_withdrbg(rng,info,state);
    return r;
}
EXPORT int ccrng_drbg_reseed(struct ccrng_drbg_state *rng,size_t n,const void *entropy,size_t extra_size,const void *extra)
{ return rng->info->reseed(rng->state,n,entropy,extra_size,extra); }
EXPORT void ccrng_drbg_done(struct ccrng_drbg_state *rng) { rng->info->done(rng->state);rng->state=NULL; }
