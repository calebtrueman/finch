/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccrsa.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
struct test_rng {struct ccrng_state base;uint64_t value;};
static int seeded(struct ccrng_state*r,size_t n,void*out){struct test_rng*s=(void*)r;unsigned char*p=out;while(n--){s->value^=s->value<<13;s->value^=s->value>>7;s->value^=s->value<<17;*p++=s->value;}return 0;}
static int random_(struct ccrng_state*r,size_t n,void*p){(void)r;arc4random_buf(p,n);return 0;}
static unsigned count,fail;
#define CK(x) do{count++;if(!(x)){fail++;fprintf(stderr,"line %d: %s\n",__LINE__,#x);}}while(0)
#define LOAD(ret,name,args) ret(*h_##name)args=dlsym(h,#name);ret(*f_##name)args=dlsym(f,#name)
int main(int argc,char**argv){void*h=dlopen("/usr/lib/system/libcorecrypto.dylib",2),*f=dlopen(argc>1?argv[1]:"build/userland/corecrypto/rsa-test.dylib",2);if(!h||!f){puts(dlerror());return 2;}
 LOAD(int,ccrsa_generate_key_deterministic,(size_t,ccrsa_ctx*,size_t,const void*,size_t,const void*,size_t,const void*,unsigned,struct ccrng_state*));LOAD(int,ccrsa_generate_fips186_key,(size_t,ccrsa_ctx*,size_t,const void*,struct ccrng_state*,struct ccrng_state*));LOAD(size_t,ccrsa_export_priv_size,(const ccrsa_ctx*));LOAD(int,ccrsa_export_priv,(const ccrsa_ctx*,size_t,void*));
 unsigned char entropy[32],nonce[16],e[]={1,0,1};for(unsigned i=0;i<32;i++)entropy[i]=i;for(unsigned i=0;i<16;i++)nonce[i]=i+32;struct ccrng_state mr={random_};
 for(unsigned kind=0;kind<2;kind++)for(unsigned bits=512;bits<=2048;bits*=2)for(unsigned seed=1;seed<=2;seed++){
 cc_unit hk[4096]={0},fk[4096]={0};ccrsa_ctx*hc=(void*)hk,*fc=(void*)fk;struct test_rng hr={{seeded},seed*76321},fr=hr;int a,b;entropy[0]=(unsigned char)seed;
 if(!kind){a=h_ccrsa_generate_key_deterministic(bits,hc,3,e,32,entropy,16,nonce,1,&mr);b=f_ccrsa_generate_key_deterministic(bits,fc,3,e,32,entropy,16,nonce,1,&mr);}else{a=h_ccrsa_generate_fips186_key(bits,hc,3,e,&hr.base,&mr);b=f_ccrsa_generate_fips186_key(bits,fc,3,e,&fr.base,&mr);}
 fprintf(stderr,"%s %u seed%u host=%d finch=%d\n",kind?"FIPS":"deterministic",bits,seed,a,b);CK(a==b);CK(a==0);if(a||b)continue;
 size_t hn=h_ccrsa_export_priv_size(hc),fn=f_ccrsa_export_priv_size(fc);CK(hn==fn);unsigned char hb[8192],fb[8192];CK(h_ccrsa_export_priv(hc,hn,hb)==0);CK(f_ccrsa_export_priv(fc,fn,fb)==0);CK(hn==fn&&!memcmp(hb,fb,hn));if(memcmp(hb,fb,hn<fn?hn:fn))fprintf(stderr,"p bits %zu/%zu q bits %zu/%zu rngstate %llx/%llx\n",finch_rsa_p(hc)->bitlen,finch_rsa_p(fc)->bitlen,finch_rsa_q(hc)->bitlen,finch_rsa_q(fc)->bitlen,(unsigned long long)hr.value,(unsigned long long)fr.value);
 }
 printf("RSA key generation ABI: %u checks, %u failures\n",count,fail);return !!fail;}
