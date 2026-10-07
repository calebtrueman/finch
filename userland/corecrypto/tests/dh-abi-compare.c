/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccdh.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);exit(1);}}while(0)
struct rng {struct ccrng_state state;unsigned v,calls,fail;size_t sizes[8];};
static int draw(struct ccrng_state*r,size_t n,void*p){struct rng*x=(void*)r;if(x->calls<8)x->sizes[x->calls]=n;x->calls++;if(x->fail==x->calls)return -99;for(size_t i=0;i<n;i++)((unsigned char*)p)[i]=(unsigned char)(++x->v*17+29);return 0;}
int main(int argc,char**argv){if(argc!=2)return 2;void*h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",2),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL)};CHECK(h[0]&&h[1]);
 const char*names[]={"apple768","rfc2409group02","rfc3526group05","rfc3526group14","rfc3526group15","rfc3526group16","rfc3526group17","rfc3526group18","rfc5114_MODP_1024_160","rfc5114_MODP_2048_224","rfc5114_MODP_2048_256"};
 for(int group=0;group<11;group++){
  char name[100];snprintf(name,sizeof name,"ccdh_gp_%s",names[group]);const struct cczp*gp[2];
  for(int j=0;j<2;j++){const struct cczp*(*get)(void)=dlsym(h[j],name);CHECK(get);gp[j]=get();}
  CHECK(gp[0]->n==gp[1]->n&&gp[0]->bitlen==gp[1]->bitlen);size_t n=gp[0]->n;
  for(size_t k=0;k<4*n+2;k++)if(gp[0]->data[k]!=gp[1]->data[k])fprintf(stderr,"group %d word %zu host %llx Finch %llx\n",group,k,(unsigned long long)gp[0]->data[k],(unsigned long long)gp[1]->data[k]); CHECK(!memcmp(gp[0]->data,gp[1]->data,32*n+16));

  size_t(*der_size[2])(const struct cczp*);unsigned char*(*der_encode[2])(const struct cczp*,unsigned char*,unsigned char*);const unsigned char*(*der_decode[2])(struct cczp*,const unsigned char*,const unsigned char*);
  unsigned char der[2][2200];size_t derlen[2];
  for(int j=0;j<2;j++){der_size[j]=dlsym(h[j],"ccder_encode_dhparams_size");der_encode[j]=dlsym(h[j],"ccder_encode_dhparams");der_decode[j]=dlsym(h[j],"ccder_decode_dhparams");CHECK(der_size[j]&&der_encode[j]&&der_decode[j]);derlen[j]=der_size[j](gp[1-j]);memset(der[j],0xa5,sizeof der[j]);CHECK(der_encode[j](gp[1-j],der[j],der[j]+derlen[j])==der[j]);}
  CHECK(derlen[0]==derlen[1]&&!memcmp(der[0],der[1],sizeof der[0]));
  for(size_t take=0;take<=derlen[0];take++){
   uint64_t result[2][520];const unsigned char*ret[2];
   for(int j=0;j<2;j++){memset(result[j],0xa5,sizeof result[j]);result[j][0]=n;ret[j]=der_decode[j]((void*)result[j],der[0],der[0]+take);}
   CHECK(ret[0]==ret[1]);CHECK(!memcmp(result[0],result[1],16));CHECK(!memcmp(result[0]+3,result[1]+3,sizeof result[0]-24));
  }
  for(int which=0;which<2;which++){
   unsigned char ctx[2][2080],bytes[1100],pub[2][1100];memset(bytes,0,sizeof bytes);bytes[0]=7;
   int(*import[2])(const struct cczp*,size_t,const void*,struct ccdh_ctx*);void(*export[2])(const struct ccdh_ctx*,void*);
   for(int j=0;j<2;j++){import[j]=dlsym(h[j],which?"ccdh_import_pub":"ccdh_import_priv");export[j]=dlsym(h[j],"ccdh_export_pub");CHECK(import[j]&&export[j]);}
   for(size_t bn=0;bn<=3;bn++){
    int ret[2];for(int j=0;j<2;j++){memset(ctx[j],0xa5,sizeof ctx[j]);ret[j]=import[j](gp[1-j],bn,bytes,(void*)ctx[j]);}CHECK(ret[0]==ret[1]);CHECK(!memcmp(ctx[0]+8,ctx[1]+8,sizeof ctx[0]-8));
    if(!ret[0]){for(int j=0;j<2;j++){memset(pub[j],0xa5,sizeof pub[j]);export[j]((void*)ctx[1-j],pub[j]);}CHECK(!memcmp(pub[0],pub[1],sizeof pub[0]));}
   }
  }
  unsigned char ctx[2][2080];int(*generate[2])(const struct cczp*,struct ccrng_state*,struct ccdh_ctx*);
  for(int j=0;j<2;j++){generate[j]=dlsym(h[j],"ccdh_generate_key");CHECK(generate[j]);struct rng r={.state={draw}};memset(ctx[j],0xa5,sizeof ctx[j]);CHECK(!generate[j](gp[1-j],&r.state,(void*)ctx[j]));}
  CHECK(!memcmp(ctx[0]+8,ctx[1]+8,sizeof ctx[0]-8));
  for(unsigned fail=1;fail<=4;fail++){
   unsigned char bad[2][2080];struct rng r[2]={ {.state={draw},.fail=fail}, {.state={draw},.fail=fail} };int ret[2];
   for(int j=0;j<2;j++){memset(bad[j],0xa5,sizeof bad[j]);ret[j]=generate[j](gp[1-j],&r[j].state,(void*)bad[j]);}
   CHECK(ret[0]==ret[1]);CHECK(r[0].calls==r[1].calls);CHECK(!memcmp(r[0].sizes,r[1].sizes,sizeof r[0].sizes));CHECK(!memcmp(bad[0]+8,bad[1]+8,sizeof bad[0]-8));
  }
  int(*shared[2])(const struct ccdh_ctx*,const struct ccdh_ctx*,size_t*,void*,struct ccrng_state*);
  unsigned char secret[2][1100];size_t len[2]={sizeof secret[0],sizeof secret[1]};
  for(int j=0;j<2;j++){shared[j]=dlsym(h[j],"ccdh_compute_shared_secret");CHECK(shared[j]);struct rng r={.state={draw},.v=3};memset(secret[j],0xa5,sizeof secret[j]);CHECK(!shared[j]((void*)ctx[1-j],(void*)ctx[j],&len[j],secret[j],&r.state));}
  CHECK(len[0]==len[1]&&!memcmp(secret[0],secret[1],sizeof secret[0]));printf("DH %s passed\n",names[group]);
 }

 int(*init[2])(struct cczp*,size_t,size_t,const void*,size_t,const void*,size_t,const void*,size_t);
 for(int j=0;j<2;j++){init[j]=dlsym(h[j],"ccdh_init_gp_from_bytes");CHECK(init[j]);}
 for(unsigned p=2;p<100;p++)for(unsigned qcase=0;qcase<3;qcase++){
  unsigned char prime=p,gen=2,order=11;uint64_t buf[2][64];int ret[2];
  for(int j=0;j<2;j++){memset(buf[j],0xa5,sizeof buf[j]);ret[j]=init[j]((void*)buf[j],1,1,&prime,1,&gen,qcase?1:0,qcase?&order:NULL,qcase==2?3:0);}
  if(ret[0]!=ret[1])fprintf(stderr,"init p=%u qcase=%u return %d %d\n",p,qcase,ret[0],ret[1]);CHECK(ret[0]==ret[1]);
  CHECK(!memcmp(buf[0],buf[1],16));CHECK(!memcmp(buf[0]+3,buf[1]+3,sizeof buf[0]-24));
 }
 printf("DH: %u checks passed\n",checks);
}
