/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ascon.h"
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
/* ASCON-128a uses five 64-bit words and the original big-endian byte order. */
struct ascon_ctx { uint64_t x[5], used; };
static void wipe(void *p,size_t n) { volatile unsigned char *b=p;while(n--)*b++=0; }
static uint64_t load(const void *p) { const unsigned char *b=p;uint64_t x=0;for(int i=0;i<8;i++)x=(x<<8)|b[i];return x; }
static uint64_t ror(uint64_t x,unsigned n) { return (x>>n)|(x<<(64-n)); }
static void permute(struct ascon_ctx *c,unsigned rounds) {
    uint64_t *x=c->x;
    for(unsigned r=12-rounds;r<12;r++) {
        x[2]^=((15-r)<<4)|r; x[0]^=x[4];x[4]^=x[3];x[2]^=x[1];
        uint64_t t[5];for(unsigned i=0;i<5;i++)t[i]=~x[i]&x[(i+1)%5];for(unsigned i=0;i<5;i++)x[i]^=t[(i+1)%5];
        x[1]^=x[0];x[0]^=x[4];x[3]^=x[2];x[2]=~x[2];
        x[0]^=ror(x[0],19)^ror(x[0],28); x[1]^=ror(x[1],61)^ror(x[1],39); x[2]^=ror(x[2],1)^ror(x[2],6); x[3]^=ror(x[3],10)^ror(x[3],17); x[4]^=ror(x[4],7)^ror(x[4],41);
    }
}
static void accumulate(struct ascon_ctx *c,void *output,size_t n,const void *input,int dec) {
    const unsigned char *in=input;unsigned char *out=output;size_t at=0;
    for(size_t i=0;i<n;i++) { unsigned shift=56-(at%8)*8; uint64_t b=in[i]; unsigned char v=(c->x[at/8]>>shift)^b;
        if(dec)c->x[at/8]=(c->x[at/8]&~(UINT64_C(255)<<shift))|(b<<shift);else c->x[at/8]^=b<<shift;
        if(out)out[i]=v;if(++at==16){permute(c,8);at=0;}
    }
    c->used=at;
}
static void pad(struct ascon_ctx *c) { c->x[c->used/8]^=UINT64_C(0x80)<<(56-(c->used%8)*8); }
static int init(void *p,size_t an,const void *aad,const void *nonce,const void *key) {
    struct ascon_ctx *c=p; uint64_t k0=load(key),k1=load((const char*)key+8);
    *c=(struct ascon_ctx){{UINT64_C(0x80800c0800000000),k0,k1,load(nonce),load((const char*)nonce+8)},0};
    permute(c,12);c->x[3]^=k0;c->x[4]^=k1;
    if(an){accumulate(c,NULL,an,aad,0);pad(c);permute(c,8);}c->x[4]^=1;return 0;
}
static void finalize(struct ascon_ctx *c,void *tag,const void *key) { uint64_t k0=load(key),k1=load((const char*)key+8);c->x[2]^=k0;c->x[3]^=k1;permute(c,12);c->x[3]^=k0;c->x[4]^=k1;unsigned char *o=tag;for(size_t i=0;i<16;i++)o[i]=c->x[3+i/8]>>(56-(i%8)*8); }
static int encrypt(void *p,void *out,void *tag,size_t n,const void *in,const void *key) { struct ascon_ctx *c=p;accumulate(c,out,n,in,0);pad(c);finalize(c,tag,key);return 0; }
static int decrypt(void *p,void *out,const void *tag,size_t n,const void *in,const void *key) { struct ascon_ctx *c=p;unsigned char check[16];accumulate(c,out,n,in,1);pad(c);finalize(c,check,key);unsigned diff=0;for(size_t i=0;i<16;i++)diff|=check[i]^((const unsigned char *)tag)[i];wipe(check,16);if(diff){if(out)wipe(out,n);wipe(c,sizeof(*c));return -2;}return 0; }
static int process(void *p,size_t n,const void *in) { accumulate(p,NULL,n,in,0);return 0; }
static int tag(const void *p,void *out,const void *key) { struct ascon_ctx copy=*(const struct ascon_ctx *)p;pad(&copy);finalize(&copy,out,key);wipe(&copy,sizeof(copy));return 0; }
static int verify(const void *p,size_t n,const void *expected,const void *key) { unsigned char check[16];tag(p,check,key);unsigned diff=!n;if(n>16){wipe(check,16);return -2;}for(size_t i=0;i<n;i++)diff|=check[i]^((const unsigned char *)expected)[i];wipe(check,16);return diff?-2:0; }
EXPORT const struct ccascon_info ccascon_ascon128a_ref={16,16,16,init,encrypt,decrypt};
EXPORT const struct ccascon_cmac_info ccascon_ascon128a_cmac_ref={16,16,16,init,process,tag,verify};
EXPORT const struct ccascon_info *ccascon_ascon128a(void) { return &ccascon_ascon128a_ref; }
EXPORT const struct ccascon_cmac_info *ccascon_ascon128a_cmac(void) { return &ccascon_ascon128a_cmac_ref; }
EXPORT int ccascon_ascon128a_encrypt(const struct ccascon_info *m,void *out,void *t,size_t n,const void *in,size_t an,const void *aad,const void *nonce,const void *key) { struct ascon_ctx c={0};m->init(&c,an,aad,nonce,key);int r=m->encrypt(&c,out,t,n,in,key);wipe(&c,sizeof(c));return r; }
EXPORT int ccascon_ascon128a_decrypt(const struct ccascon_info *m,void *out,const void *t,size_t n,const void *in,size_t an,const void *aad,const void *nonce,const void *key) { struct ascon_ctx c={0};m->init(&c,an,aad,nonce,key);int r=m->decrypt(&c,out,t,n,in,key);wipe(&c,sizeof(c));return r; }
EXPORT int ccascon_cmac_init(const struct ccascon_cmac_info *m,void *c,size_t n,const void *aad,const void *nonce,const void *key) { return m->init(c,n,aad,nonce,key); }
EXPORT int ccascon_cmac_process(const struct ccascon_cmac_info *m,void *c,size_t n,const void *in) { return m->process(c,n,in); }
EXPORT int ccascon_cmac_tag(const struct ccascon_cmac_info *m,const void *c,void *out,const void *key) { return m->tag(c,out,key); }
EXPORT int ccascon_cmac_verify(const struct ccascon_cmac_info *m,const void *c,size_t n,const void *t,const void *key) { return m->verify(c,n,t,key); }
