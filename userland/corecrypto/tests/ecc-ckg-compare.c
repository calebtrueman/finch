/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccec.h"
#include "../abi/ccdigest.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define F(H,N,T) ((T)dlsym(H,#N))
#define C(X) do{if(!(X)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#X);exit(1);}checks++;}while(0)
static int checks;
static int random_bytes(struct ccrng_state*r,size_t n,void*out){(void)r;arc4random_buf(out,n);return 0;}
static struct ccrng_state rng={random_bytes};
typedef size_t(*size1)(const void*,const void*);typedef size_t(*size2)(const void*);
typedef int(*init1)(void*,const void*,const void*,void*);typedef int(*init2)(void*,const void*);
typedef int(*commit1)(void*,size_t,void*);typedef int(*commit2)(void*,size_t,void*,void*);
typedef int(*share1)(void*,size_t,const void*,size_t,void*);typedef int(*share2)(void*,size_t,const void*,size_t,void*,void*);
typedef int(*contrib1)(void*,size_t,const void*,size_t,void*,void*,size_t,void*);typedef int(*contrib2)(void*,size_t,const void*,size_t,void*,void*,size_t,void*,void*);
typedef int(*owner1)(void*,size_t,const void*,void*,size_t,void*);typedef int(*owner2)(void*,size_t,const void*,void*,size_t,void*,void*);
int main(int argc,char**argv){C(argc==2);void*h=dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),*f=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!f)fprintf(stderr,"%s\n",dlerror());C(h&&f);const void*di=((const void*(*)(void))dlsym(h,"ccsha256_di"))();int bits[]={192,224,256,384,521};
 for(int i=0;i<5;i++)for(int mode=0;mode<4;mode++){
 const struct cczp*cp=((const struct cczp*(*)(size_t))dlsym(h,"ccec_get_cp"))(bits[i]);void*ch=mode&1?f:h,*oh=mode&2?f:h;
 size_t cn=F(h,ccckg_sizeof_commitment,size1)(cp,di),sn=F(h,ccckg_sizeof_share,size1)(cp,di),on=F(h,ccckg_sizeof_opening,size1)(cp,di),ctxn=F(h,ccckg_sizeof_ctx,size1)(cp,di);
 C(cn==F(f,ccckg_sizeof_commitment,size1)(cp,di)&&sn==F(f,ccckg_sizeof_share,size1)(cp,di)&&on==F(f,ccckg_sizeof_opening,size1)(cp,di)&&ctxn==F(f,ccckg_sizeof_ctx,size1)(cp,di));
 unsigned char a[512]={0},b[512]={0},acopy[512],bcopy[512],pub[304]={0},full[304]={0},commit[64],share[200],opening[200],ka[71],kb[71];*(const void**)pub=cp;*(const void**)full=cp;
 C(!F(ch,ccckg_init,init1)(a,cp,di,&rng));C(!F(oh,ccckg_init,init1)(b,cp,di,&rng));C(!F(ch,ccckg_contributor_commit,commit1)(a,cn,commit));C(F(ch,ccckg_contributor_commit,commit1)(a,cn,commit)==-86);
 C(!F(oh,ccckg_owner_generate_share,share1)(b,cn,commit,sn,share));memcpy(acopy,a,ctxn);memcpy(bcopy,b,ctxn);
 C(!F(ch,ccckg_contributor_finish,contrib1)(a,sn,share,on,opening,pub,sizeof(ka),ka));C(!F(oh,ccckg_owner_finish,owner1)(b,on,opening,full,sizeof(kb),kb));C(!memcmp(ka,kb,sizeof(ka)));C(!memcmp(pub+16,full+16,16*cp->n));
 /* Contexts made by either implementation can finish in the other one. */
 C(!F(ch==h?f:h,ccckg_contributor_finish,contrib1)(acopy,sn,share,on,opening,pub,sizeof(ka),ka));C(!F(oh==h?f:h,ccckg_owner_finish,owner1)(bcopy,on,opening,full,sizeof(kb),kb));C(!memcmp(ka,kb,sizeof(ka)));
 }
 for(int mode=0;mode<4;mode++){
 const void*params=((const void*(*)(void))dlsym(h,"ccckg2_params_p224_sha256_v2"))();void*ch=mode&1?f:h,*oh=mode&2?f:h;size_t cn=F(h,ccckg2_sizeof_commitment,size2)(params),sn=F(h,ccckg2_sizeof_share,size2)(params),on=F(h,ccckg2_sizeof_opening,size2)(params),ctxn=F(h,ccckg2_sizeof_ctx,size2)(params);C(cn==F(f,ccckg2_sizeof_commitment,size2)(params)&&sn==F(f,ccckg2_sizeof_share,size2)(params)&&on==F(f,ccckg2_sizeof_opening,size2)(params)&&ctxn==F(f,ccckg2_sizeof_ctx,size2)(params));
 unsigned char a[512]={0},b[512]={0},acopy[512],bcopy[512],pub[304]={0},full[304]={0},commit[64],share[200],opening[200],ka[71],kb[71];C(!F(ch,ccckg2_init,init2)(a,params));C(!F(oh,ccckg2_init,init2)(b,params));const struct cczp*cp=((const struct cczp*(*)(void*))dlsym(ch,"ccckg2_ctx_cp"))(a);*(const void**)pub=cp;*(const void**)full=cp;
 C(!F(ch,ccckg2_contributor_commit,commit2)(a,cn,commit,&rng));C(!F(oh,ccckg2_owner_generate_share,share2)(b,cn,commit,sn,share,&rng));memcpy(acopy,a,ctxn);memcpy(bcopy,b,ctxn);
 C(!F(ch,ccckg2_contributor_finish,contrib2)(a,sn,share,on,opening,pub,sizeof(ka),ka,&rng));C(!F(oh,ccckg2_owner_finish,owner2)(b,on,opening,full,sizeof(kb),kb,&rng));C(!memcmp(ka,kb,sizeof(ka)));C(!memcmp(pub+16,full+16,16*cp->n));
 C(!F(ch==h?f:h,ccckg2_contributor_finish,contrib2)(acopy,sn,share,on,opening,pub,sizeof(ka),ka,&rng));C(!F(oh==h?f:h,ccckg2_owner_finish,owner2)(bcopy,on,opening,full,sizeof(kb),kb,&rng));C(!memcmp(ka,kb,sizeof(ka)));
 }
 printf("%d two-party key checks passed\n",checks);
}
