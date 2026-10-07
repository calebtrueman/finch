/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccec.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int checks,failures;
#define CHECK(X) do{checks++;if(!(X)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#X);failures++;}}while(0)
struct rng{struct ccrng_state r;unsigned seed;};
static int bytes(struct ccrng_state*r,size_t n,void*out){for(size_t j=0;j<n;j++)((unsigned char*)out)[j]=((struct rng*)r)->seed+13*j;return 0;}
int main(int argc,char**argv){void*h=dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),*f=dlopen(argc>1?argv[1]:"build/userland/corecrypto/sigma-test.dylib",RTLD_NOW|RTLD_LOCAL);if(!h||!f)return 2;const char*curves[]={"ccec_cp_192","ccec_cp_224","ccec_cp_256","ccec_cp_384","ccec_cp_521"},*names[]={"ccec_generate_key","ccec_generate_key_fips","ccec_generate_key_legacy","ccecdh_generate_key"};for(unsigned c=0;c<5;c++)for(unsigned n=0;n<4;n++)for(unsigned seed=1;seed<4;seed++){const struct cczp*cp=((const struct cczp*(*)(void))dlsym(h,curves[c]))();int(*hg)(ccec_const_cp_t,struct ccrng_state*,struct ccec_ctx*)=dlsym(h,names[n]);int(*fg)(ccec_const_cp_t,struct ccrng_state*,struct ccec_ctx*)=dlsym(f,names[n]);unsigned char a[304]={0},b[304]={0},ha[66],hb[66],sa[66],sb[66],hash[64];memset(hash,5,sizeof hash);struct rng ra={{bytes},seed*17},rb={{bytes},seed*17};int x=hg(cp,&ra.r,(void*)a),y=fg(cp,&rb.r,(void*)b);CHECK(x==y);CHECK(!x);CHECK(!memcmp(a,b,16+cp->n*32));int(*hs)(const struct ccec_ctx*,size_t,const void*,void*,void*,struct ccrng_state*)=dlsym(h,"ccec_sign_composite"),(*fs)(const struct ccec_ctx*,size_t,const void*,void*,void*,struct ccrng_state*)=dlsym(f,"ccec_sign_composite");CHECK(hs((void*)a,64,hash,ha,sa,&ra.r)==fs((void*)b,64,hash,hb,sb,&rb.r));CHECK(!memcmp(ha,hb,(cp->bitlen+7)/8));CHECK(!memcmp(sa,sb,(cp->bitlen+7)/8));}printf("Seeded ECC ABI: %d checks, %d failures\n",checks,failures);return failures?1:0;}
