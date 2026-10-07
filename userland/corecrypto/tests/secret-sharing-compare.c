/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccss.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct random_state {struct ccrng_state api;unsigned counter;};
static int random_bytes(struct ccrng_state*r,size_t n,void*out){struct random_state*s=(void*)r;for(size_t i=0;i<n;i++)((unsigned char*)out)[i]=(unsigned char)(++s->counter*73+19);return 0;}
static unsigned checks,failed;
#define CHECK(X) do{checks++;if(!(X)){if(failed++<15)fprintf(stderr,"line %d: %s\n",__LINE__,#X);}}while(0)
struct api {
 size_t(*params_size)(size_t);size_t(*gen_size)(const struct ccss_parameters*);size_t(*share_size)(const struct ccss_parameters*);size_t(*bag_size)(const struct ccss_parameters*);
 int(*params)(struct ccss_parameters*,size_t,const void*,uint32_t);
 int(*gen)(struct ccss_value*,const struct ccss_parameters*,struct ccrng_state*,const void*,size_t);
 int(*loose)(struct ccss_value*,const struct ccss_parameters*,struct ccrng_state*,const void*,size_t);
 void(*share)(struct ccss_value*,const struct ccss_parameters*);int(*generate)(const struct ccss_value*,uint32_t,struct ccss_value*);
 int(*export)(const struct ccss_value*,uint32_t*,void*,size_t);int(*import)(struct ccss_value*,uint32_t,const void*,size_t);
 void(*bag)(struct ccss_bag*,const struct ccss_parameters*);int(*add)(struct ccss_bag*,const struct ccss_value*);int(*recover)(const struct ccss_bag*,void*,size_t);
 bool(*size)(const struct ccss_value*,size_t*);int(*serialize)(size_t,void*,const struct ccss_value*);int(*deserialize)(struct ccss_value*,const struct ccss_parameters*,size_t,const void*);
};
static void bind(struct api*a,void*h){
#define B(F,N) do{*(void**)(&a->F)=dlsym(h,N);if(!a->F){fprintf(stderr,"missing %s\n",N);exit(2);}}while(0)
 B(params_size,"ccss_sizeof_parameters");B(gen_size,"ccss_sizeof_generator");B(share_size,"ccss_sizeof_share");B(bag_size,"ccss_sizeof_share_bag");B(params,"ccss_shamir_parameters_init");B(gen,"ccss_shamir_share_generator_init");B(loose,"ccss_shamir_share_generator_init_with_secrets_less_than_prime");B(share,"ccss_shamir_share_init");B(generate,"ccss_shamir_share_generator_generate_share");B(export,"ccss_shamir_share_export");B(import,"ccss_shamir_share_import");B(bag,"ccss_shamir_share_bag_init");B(add,"ccss_shamir_share_bag_add_share");B(recover,"ccss_shamir_share_bag_recover_secret");B(size,"ccss_sizeof_shamir_share_generator_serialization");B(serialize,"ccss_shamir_share_generator_serialize");B(deserialize,"ccss_shamir_share_generator_deserialize");
}
int main(int argc,char**argv){if(argc!=2)return 2;void*h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL)};if(!h[0]||!h[1]){puts(dlerror());return 2;}struct api a[2];bind(a,h[0]);bind(a+1,h[1]);
 int bits[]={192,224,256,384,521};
 for(int curve=0;curve<5;curve++)for(unsigned t=2;t<=6;t++){
  char name[40];snprintf(name,sizeof(name),"CCSS_PRIME_P%d",bits[curve]);size_t pn=(bits[curve]+7)/8;const void*prime=dlsym(h[0],name);CHECK(!memcmp(prime,dlsym(h[1],name),pn));
  struct ccss_parameters*p[2];struct ccss_value*g[2],*s[2];struct ccss_bag*b[2];size_t sn[2];unsigned char serial[2][1024],secret[80]={1,2,3,4,5},out[2][100];
  for(int k=0;k<2;k++){p[k]=calloc(1,a[k].params_size(pn));CHECK(a[k].params(p[k],pn,prime,t)==0);g[k]=calloc(1,a[k].gen_size(p[k]));s[k]=calloc(1,a[k].share_size(p[k]));b[k]=calloc(1,a[k].bag_size(p[k]));struct random_state r={{random_bytes},0};int gr=a[k].gen(g[k],p[k],&r.api,secret,5);if(gr)fprintf(stderr,"curve %d k %d gen %d n %zu bits %zu\n",curve,k,gr,p[k]->prime.n,p[k]->prime.bitlen);CHECK(gr==0);a[k].share(s[k],p[k]);a[k].bag(b[k],p[k]);CHECK(a[k].size(g[k],sn+k));CHECK(a[k].serialize(sizeof(serial[k]),serial[k],g[k])==0);}
  CHECK(sn[0]==sn[1]);CHECK(!memcmp(serial[0],serial[1],sn[0]));
  for(unsigned x=1;x<=t;x++){
   for(int k=0;k<2;k++){CHECK(a[k].generate(g[k],x,s[k])==0);memset(out[k],0xa5,100);uint32_t xx=0;CHECK(a[k].export(s[k],&xx,out[k],pn)==0);CHECK(xx==x);CHECK(a[k].add(b[k],s[k])==0);}
   CHECK(!memcmp(out[0],out[1],100));
  }
  for(size_t len=0;len<=pn+2;len++){memset(out,0xa5,sizeof(out));int r[2];for(int k=0;k<2;k++)r[k]=a[k].recover(b[k],out[k],len);CHECK(r[0]==r[1]);CHECK(!memcmp(out[0],out[1],100));}
  /* Saved data rejects truncation, bad versions, and invalid coefficients. */
  for(size_t cut=0;cut<sn[0];cut++){int r[2];for(int k=0;k<2;k++)r[k]=a[k].deserialize(g[k],p[k],cut,serial[0]);CHECK(r[0]==r[1]);}
  for(size_t pos=0;pos<sn[0];pos++){unsigned char bad[1024];memcpy(bad,serial[0],sn[0]);bad[pos]^=0xff;int r[2];for(int k=0;k<2;k++)r[k]=a[k].deserialize(g[k],p[k],sn[0],bad);CHECK(r[0]==r[1]);}
  for(size_t len=0;len<=pn+1;len++)for(int loose=0;loose<2;loose++){
   int r[2];for(int k=0;k<2;k++){struct random_state rng={{random_bytes},0};r[k]=(loose?a[k].loose:a[k].gen)(g[k],p[k],&rng.api,secret,len);}CHECK(r[0]==r[1]);
  }
  for(size_t len=0;len<=pn+1;len++){
   int r[2];uint32_t xx[2]={0x12345678,0x12345678};memset(out,0xa5,sizeof(out));
   for(int k=0;k<2;k++)r[k]=a[k].export(s[k],xx+k,out[k],len);CHECK(r[0]==r[1]);CHECK(xx[0]==xx[1]);CHECK(!memcmp(out[0],out[1],100));
   for(int k=0;k<2;k++)r[k]=a[k].import(s[k],55,secret,len);CHECK(r[0]==r[1]);CHECK(!memcmp(s[0]->data,s[1]->data,p[0]->prime.n*8));
  }
  for(int k=0;k<2;k++){CHECK(a[k].deserialize(g[k],p[k],sn[1-k],serial[1-k])==0);CHECK(a[k].generate(g[k],0,s[k])==-131);CHECK(a[k].add(b[k],s[k])==-126);free(p[k]);free(g[k]);free(s[k]);free(b[k]);}
 }
 printf("secret sharing: %u checks, %u failures\n",checks,failed);return failed?1:0;
}
