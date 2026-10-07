/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccec.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#define LOAD(H,N,T) ((T)dlsym(H,#N))
#define CHECK(X) do{if(!(X)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#X);exit(1);}checks++;}while(0)
static int checks;
static int random_bytes(struct ccrng_state*r,size_t n,void*out){(void)r;arc4random_buf(out,n);return 0;}
static int bad_random(struct ccrng_state*r,size_t n,void*p){(void)r;(void)n;(void)p;return -123;}
static struct ccrng_state rng={random_bytes},bad_rng={bad_random};
typedef const struct cczp*(*getcp)(size_t);
typedef int(*gen)(const struct cczp*,struct ccrng_state*,void*);
typedef int(*exportfn)(bool,void*,const void*);
typedef int(*importfn)(const struct cczp*,size_t,const void*,void*);
typedef int(*signfn)(const void*,size_t,const void*,size_t*,void*,struct ccrng_state*);
typedef int(*verifyfn)(const void*,size_t,const void*,size_t,const void*,bool*);
typedef int(*dhfn)(const void*,const void*,size_t*,void*,struct ccrng_state*);
int main(int argc,char**argv){CHECK(argc==2);void*h=dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),*f=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!f)fprintf(stderr,"%s\n",dlerror());CHECK(h&&f);int bs[]={192,224,256,384,521};for(int i=0;i<5;i++){
 const struct cczp*cp=LOAD(h,ccec_get_cp,getcp)(bs[i]);const struct cczp*fp=LOAD(f,ccec_get_cp,getcp)(bs[i]);CHECK(cp&&fp&&cp->n==fp->n&&cp->bitlen==fp->bitlen);CHECK(!memcmp(cp->data,fp->data,cp->n*8));
 unsigned char a[512]={0},b[512]={0},copy[512]={0},x[220],y[220],sig[160],hash[64]={42};size_t w=(bs[i]+7)/8;
 CHECK(!LOAD(h,ccec_generate_key,gen)(cp,&rng,a));CHECK(!LOAD(f,ccec_generate_key,gen)(cp,&rng,b));
 CHECK(!LOAD(h,ccec_x963_export,exportfn)(true,x,a));CHECK(!LOAD(f,ccec_x963_export,exportfn)(true,y,a));CHECK(!memcmp(x,y,1+3*w));
 CHECK(!LOAD(f,ccec_x963_import_priv,importfn)(cp,1+3*w,x,copy));CHECK(!memcmp(a+16,copy+16,32*cp->n));
 size_t sn=sizeof(sig);CHECK(!LOAD(f,ccec_sign,signfn)(b,32,hash,&sn,sig,&rng));bool valid=false;CHECK(!LOAD(h,ccec_verify,verifyfn)(b,32,hash,sn,sig,&valid)&&valid);
 sn=sizeof(sig);CHECK(!LOAD(h,ccec_sign,signfn)(a,32,hash,&sn,sig,&rng));CHECK(!LOAD(f,ccec_verify,verifyfn)(a,32,hash,sn,sig,&valid)&&valid);hash[0]^=1;CHECK(!LOAD(f,ccec_verify,verifyfn)(a,32,hash,sn,sig,&valid)&&!valid);
 size_t xn=sizeof(x),yn=sizeof(y);CHECK(!LOAD(h,ccecdh_compute_shared_secret,dhfn)(a,b,&xn,x,&rng));CHECK(!LOAD(f,ccecdh_compute_shared_secret,dhfn)(b,a,&yn,y,&rng));CHECK(xn==yn&&!memcmp(x,y,xn));
 /* A Finch descriptor must also work when system code reads or uses its key. */
 CHECK(!LOAD(f,ccec_generate_key,gen)(fp,&rng,b));sn=sizeof(sig);CHECK(!LOAD(h,ccec_sign,signfn)(b,32,hash,&sn,sig,&rng));CHECK(!LOAD(f,ccec_verify,verifyfn)(b,32,hash,sn,sig,&valid)&&valid);
 
 typedef int(*simpleexport)(const void*,void*);typedef int(*transform)(void*);
 CHECK(!LOAD(f,ccec_compact_transform_key,transform)(b));CHECK(!LOAD(h,ccec_compact_export_pub,simpleexport)(x,b));CHECK(!LOAD(f,ccec_compact_export_pub,simpleexport)(y,b));CHECK(!memcmp(x,y,w));
 memset(copy,0,sizeof(copy));CHECK(!LOAD(h,ccec_compact_import_pub,importfn)(cp,w,x,copy));CHECK(!memcmp(b+16,copy+16,16*cp->n));CHECK(!LOAD(f,ccec_compact_import_pub,importfn)(cp,w,x,copy));CHECK(!memcmp(b+16,copy+16,16*cp->n));
 CHECK(!LOAD(h,ccec_compressed_x962_export_pub,simpleexport)(b,x));CHECK(!LOAD(f,ccec_compressed_x962_export_pub,simpleexport)(b,y));CHECK(!memcmp(x,y,w+1));CHECK(!LOAD(f,ccec_compressed_x962_import_pub,importfn)(cp,w+1,x,copy));CHECK(!memcmp(b+16,copy+16,16*cp->n));
 typedef int(*blindgen)(const struct cczp*,struct ccrng_state*,void*,void*);typedef int(*blindop)(struct ccrng_state*,const void*,const void*,void*);
 unsigned char bk[512]={0},uk[512]={0},blinded[512]={0};*(const void**)blinded=cp;*(const void**)copy=cp;
 CHECK(!LOAD(f,ccec_generate_blinding_keys,blindgen)(cp,&rng,bk,uk));CHECK(!LOAD(h,ccec_blind,blindop)(&rng,bk,a,blinded));CHECK(!LOAD(f,ccec_unblind,blindop)(&rng,uk,blinded,copy));CHECK(!memcmp(a+16,copy+16,16*cp->n));
 CHECK(!LOAD(f,ccec_blind,blindop)(&rng,bk,a,blinded));CHECK(!LOAD(h,ccec_unblind,blindop)(&rng,uk,blinded,copy));CHECK(!memcmp(a+16,copy+16,16*cp->n));
 typedef size_t(*ds)(const void*,const void*,bool);typedef int(*de)(const void*,const void*,bool,size_t,void*);
 for(int withpub=0;withpub<2;withpub++){size_t dn=LOAD(h,ccec_der_export_priv_size,ds)(a,NULL,withpub);CHECK(dn==LOAD(f,ccec_der_export_priv_size,ds)(a,NULL,withpub));CHECK(!LOAD(h,ccec_der_export_priv,de)(a,NULL,withpub,dn,x));CHECK(!LOAD(f,ccec_der_export_priv,de)(a,NULL,withpub,dn,y));CHECK(!memcmp(x,y,dn));CHECK(!LOAD(f,ccec_der_import_priv,importfn)(cp,dn,x,copy));CHECK(!memcmp(a+16,copy+16,32*cp->n));}
 typedef int(*twin)(const struct cczp*,const void*,size_t,const void*,struct ccrng_state*,void*);unsigned char entropy[148];for(size_t j=0;j<sizeof(entropy);j++)entropy[j]=(unsigned char)(j*17+3);size_t en=2*((bs[i]+71)/8);
 *(const void**)blinded=cp;*(const void**)copy=cp;CHECK(!LOAD(h,ccec_diversify_pub_twin,twin)(cp,a,en,entropy,&rng,blinded));CHECK(!LOAD(f,ccec_diversify_pub_twin,twin)(cp,a,en,entropy,&rng,copy));CHECK(!memcmp(blinded+16,copy+16,16*cp->n));
 CHECK(!LOAD(h,ccec_diversify_priv_twin,twin)(cp,a+16+24*cp->n,en,entropy,&rng,blinded));CHECK(!LOAD(f,ccec_diversify_priv_twin,twin)(cp,a+16+24*cp->n,en,entropy,&rng,copy));CHECK(!memcmp(blinded+16,copy+16,32*cp->n));
 typedef int(*projectfn)(const struct cczp*,void*,const void*,struct ccrng_state*);typedef int(*affinefn)(const struct cczp*,void*,const void*);uint64_t proj[27],aff[18];
 CHECK(!LOAD(h,ccec_projectify,projectfn)(cp,proj,a+16,&rng));CHECK(!LOAD(f,ccec_affinify,affinefn)(cp,aff,proj));CHECK(!memcmp(aff,a+16,16*cp->n));
 CHECK(!LOAD(f,ccec_projectify,projectfn)(fp,proj,a+16,&rng));CHECK(!LOAD(h,ccec_affinify,affinefn)(fp,aff,proj));CHECK(!memcmp(aff,a+16,16*cp->n));
 sn=sizeof(sig);int he=LOAD(h,ccec_sign,signfn)(a,32,hash,&sn,sig,&bad_rng);sn=sizeof(sig);int fe=LOAD(f,ccec_sign,signfn)(a,32,hash,&sn,sig,&bad_rng);CHECK(he==fe);
 *(const void**)b=cp;xn=sizeof(x);yn=sizeof(y);he=LOAD(h,ccecdh_compute_shared_secret,dhfn)(a,b,&xn,x,&bad_rng);fe=LOAD(f,ccecdh_compute_shared_secret,dhfn)(a,b,&yn,y,&bad_rng);CHECK(he==fe);
 bool hv,fv;he=LOAD(h,ccec_verify,verifyfn)(a,32,hash,1,"x",&hv);fe=LOAD(f,ccec_verify,verifyfn)(a,32,hash,1,"x",&fv);CHECK(he==fe&&hv==fv);
 printf("curve %d passed\n",bs[i]);
 }printf("%d ECC checks passed\n",checks);return 0;}
