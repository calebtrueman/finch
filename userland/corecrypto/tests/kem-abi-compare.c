/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccpq.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
struct rng{struct ccrng_state base;uint64_t value;int fail;};
static int random_bytes(struct ccrng_state*r,size_t n,void*out){struct rng*s=(void*)r;if(s->fail)return s->fail;for(size_t i=0;i<n;i++){s->value^=s->value<<13;s->value^=s->value>>7;s->value^=s->value<<17;((unsigned char*)out)[i]=s->value;}return 0;}
static struct rng rng(uint64_t seed){struct rng r={0};r.base.generate=random_bytes;r.value=seed;return r;}
static int checks,failures;static const char*which;
#define CHECK(x) do{checks++;if(!(x)){if(failures++<20)fprintf(stderr,"%s line %d: %s\n",which,__LINE__,#x);}}while(0)
#define LOAD(name,type) type h_##name=(type)dlsym(h,#name),f_##name=(type)dlsym(f,#name);CHECK(h_##name&&f_##name)
typedef void(*initfn)(struct cckem_ctx*,const struct cckem_info*);
typedef int(*genfn)(struct cckem_ctx*,struct ccrng_state*);
typedef int(*seedfn)(struct cckem_ctx*,size_t,void*,struct ccrng_state*);
typedef int(*encfn)(struct cckem_ctx*,size_t,void*,size_t,void*,struct ccrng_state*);
typedef int(*decfn)(struct cckem_ctx*,size_t,const void*,size_t,void*);
typedef int(*exportfn)(struct cckem_ctx*,size_t*,void*);
typedef int(*importfn)(const struct cckem_info*,size_t,const void*,struct cckem_ctx*);
int main(int argc,char**argv){void*h=dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),*f=dlopen(argc>1?argv[1]:"build/userland/corecrypto/kem-test.dylib",RTLD_NOW|RTLD_LOCAL);if(!h||!f){fprintf(stderr,"%s\n",dlerror());return 2;}which="load";LOAD(cckem_full_ctx_init,initfn);LOAD(cckem_generate_key,genfn);LOAD(cckem_generate_key_with_seed,seedfn);LOAD(cckem_derive_key_from_seed,seedfn);LOAD(cckem_encapsulate,encfn);LOAD(cckem_decapsulate,decfn);LOAD(cckem_export_pubkey,exportfn);LOAD(cckem_export_privkey,exportfn);LOAD(cckem_import_pubkey,importfn);LOAD(cckem_import_privkey,importfn);
const char*names[]={"cckem_mlkem768","cckem_mlkem1024","cckem_kyber768","cckem_kyber1024","cckem_xwing_mlkem768x25519"};for(int v=0;v<5;v++){which=names[v];const struct cckem_info*hi=((const struct cckem_info*(*)(void))dlsym(h,which))(),*fi=((const struct cckem_info*(*)(void))dlsym(f,which))();CHECK(!memcmp(hi,fi,48));for(int origin=0;origin<2;origin++)for(int seed=1;seed<5;seed++){const struct cckem_info*i=origin?hi:fi;size_t sz=8+i->full_size;struct cckem_ctx*a=malloc(sz),*b=malloc(sz),*im=malloc(sz);memset(a,0xcc,sz);memset(b,0xcc,sz);h_cckem_full_ctx_init(a,i);f_cckem_full_ctx_init(b,i);CHECK(!memcmp(a,b,sz));struct rng ra=rng(seed),rb=rng(seed);unsigned char sa[64],sb[64],ca[1600],cb[1600],za[32],zb[32],priv[3200],pub[1600];int ha=h_cckem_generate_key_with_seed(a,i->seed_size,sa,&ra.base),fb=f_cckem_generate_key_with_seed(b,i->seed_size,sb,&rb.base);CHECK(ha==0);CHECK(fb==ha);CHECK(!memcmp(sa,sb,i->seed_size));CHECK(!memcmp(a->key,b->key,i->full_size));
/* Direct descriptor methods ensure Finch's implementation runs even when the
 * public wrappers are tested with the host descriptor above. */
h_cckem_full_ctx_init(a,hi);f_cckem_full_ctx_init(b,fi);ra=rng(seed);rb=rng(seed);CHECK(h_cckem_generate_key(a,&ra.base)==f_cckem_generate_key(b,&rb.base));CHECK(!memcmp(a->key,b->key,i->full_size));
ra=rng(seed+77);rb=rng(seed+77);ha=h_cckem_encapsulate(a,i->ciphertext_size,ca,32,za,&ra.base);fb=f_cckem_encapsulate(b,i->ciphertext_size,cb,32,zb,&rb.base);CHECK(!ha);CHECK(ha==fb);CHECK(!memcmp(ca,cb,i->ciphertext_size));CHECK(!memcmp(za,zb,32));CHECK(h_cckem_decapsulate(a,i->ciphertext_size,cb,32,za)==0);CHECK(f_cckem_decapsulate(b,i->ciphertext_size,ca,32,zb)==0);CHECK(!memcmp(za,zb,32));
for(int bad=0;bad<3;bad++){ca[bad*31]^=0x80;CHECK(h_cckem_decapsulate(a,i->ciphertext_size,ca,32,za)==f_cckem_decapsulate(b,i->ciphertext_size,ca,32,zb));CHECK(!memcmp(za,zb,32));}size_t pn=sizeof(pub),sn=sizeof(priv);CHECK(h_cckem_export_pubkey(a,&pn,pub)==0);CHECK(f_cckem_import_pubkey(fi,pn,pub,im)==0);CHECK(!memcmp(im->key,a->key,pn));CHECK(h_cckem_export_privkey(a,&sn,priv)==0);CHECK(f_cckem_import_privkey(fi,sn,priv,im)==0);CHECK(f_cckem_decapsulate(im,i->ciphertext_size,cb,32,zb)==h_cckem_decapsulate(a,i->ciphertext_size,cb,32,za));CHECK(!memcmp(za,zb,32));pn=sizeof(pub);sn=sizeof(priv);CHECK(f_cckem_export_pubkey(b,&pn,pub)==0);CHECK(h_cckem_import_pubkey(hi,pn,pub,im)==0);CHECK(!memcmp(im->key,b->key,pn));CHECK(f_cckem_export_privkey(b,&sn,priv)==0);CHECK(h_cckem_import_privkey(hi,sn,priv,im)==0);CHECK(h_cckem_decapsulate(im,i->ciphertext_size,cb,32,za)==f_cckem_decapsulate(b,i->ciphertext_size,cb,32,zb));CHECK(!memcmp(za,zb,32));
ra=rng(seed+20);rb=rng(seed+20);CHECK(h_cckem_derive_key_from_seed(a,i->seed_size,sa,&ra.base)==f_cckem_derive_key_from_seed(b,i->seed_size,sa,&rb.base));CHECK(!memcmp(a->key,b->key,i->full_size));CHECK(h_cckem_encapsulate(a,i->ciphertext_size-1,ca,32,za,&ra.base)==f_cckem_encapsulate(b,i->ciphertext_size-1,cb,32,zb,&rb.base));CHECK(h_cckem_decapsulate(a,i->ciphertext_size,ca,31,za)==f_cckem_decapsulate(b,i->ciphertext_size,ca,31,zb));CHECK(h_cckem_generate_key_with_seed(a,i->seed_size-1,sa,&ra.base)==f_cckem_generate_key_with_seed(b,i->seed_size-1,sb,&rb.base));pn=0;sn=0;CHECK(h_cckem_export_pubkey(a,&pn,pub)==f_cckem_export_pubkey(b,&sn,pub));CHECK(pn==sn);ra.fail=rb.fail=-99;CHECK(h_cckem_generate_key(a,&ra.base)==f_cckem_generate_key(b,&rb.base));free(a);free(b);free(im);}}
printf("KEM ABI: %d checks, %d failures\n",checks,failures);return failures?1:0;}
