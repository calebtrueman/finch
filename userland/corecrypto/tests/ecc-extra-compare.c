/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccec.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define L(H,N,T) ((T)dlsym(H,#N))
static int checks;
#define C(X) do{if(!(X)){fprintf(stderr,"line %d: %s\n",__LINE__,#X);exit(1);}checks++;}while(0)
static int random_fill(struct ccrng_state*r,size_t n,void*p){(void)r;arc4random_buf(p,n);return 0;}
static struct ccrng_state rng={random_fill};
typedef const struct cczp*(*cpfn)(size_t);
typedef int(*genfn)(const struct cczp*,struct ccrng_state*,void*);
typedef int(*detfn)(const struct cczp*,size_t,const void*,struct ccrng_state*,unsigned,void*);
typedef int(*stepfn)(struct ccrng_state*,void*,void**);
typedef int(*exportfn)(const struct cczp*,unsigned,const void*,size_t*,void*);
typedef int(*importfn)(const struct cczp*,unsigned,size_t,const void*,void*);
int main(int argc,char**argv){C(argc==2);void*h=dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),*f=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!f)puts(dlerror());C(h&&f);int bits[]={192,224,256,384,521};unsigned char entropy[800];for(size_t i=0;i<sizeof entropy;i++)entropy[i]=(unsigned char)(i*13+5);for(int j=0;j<5;j++){const struct cczp*cp=L(h,ccec_get_cp,cpfn)(bits[j]);unsigned char a[512]={0},b[512]={0},k[512]={0};C(!L(h,ccec_generate_key,genfn)(cp,&rng,k));for(unsigned flags=0;flags<32;flags++){int x=L(h,ccec_generate_key_deterministic,detfn)(cp,(flags&25)==25?sizeof entropy:80,entropy,&rng,flags,a),y=L(f,ccec_generate_key_deterministic,detfn)(cp,(flags&25)==25?sizeof entropy:80,entropy,&rng,flags,b);if(x!=y)fprintf(stderr,"bits %d flags %u host %d finch %d\n",bits[j],flags,x,y);C(x==y);if(!x)C(!memcmp(a+16,b+16,32*cp->n));}for(unsigned form=1;form<=4;form++){unsigned char x[160],y[160],ax[144],bx[144];size_t xn=sizeof x,yn=sizeof y;C(!L(h,ccec_export_affine_point,exportfn)(cp,form,k+16,&xn,x));C(!L(f,ccec_export_affine_point,exportfn)(cp,form,k+16,&yn,y));C(xn==yn&&!memcmp(x,y,xn));int ar=L(h,ccec_import_affine_point,importfn)(cp,form,xn,x,ax),br=L(f,ccec_import_affine_point,importfn)(cp,form,xn,x,bx);C(ar==br);if(!ar)C(!memcmp(ax,bx,16*cp->n));}
for(int mask=0;mask<8;mask++){unsigned char state[640]={0};C(!L(f,ccec_compact_generate_key_init,genfn)(cp,&rng,state));void*out=NULL;for(int i=0;i<3;i++)C(!L((mask>>i)&1?h:f,ccec_compact_generate_key_step,stepfn)(&rng,state,&out));C(out&&((unsigned char*)state)[8]==4);}
typedef int(*divfn)(const struct cczp*,const void*,size_t,const void*,struct ccrng_state*,void*,void*);unsigned char ga[512]={0},gb[512]={0};C(!L(h,ccec_diversify_pub,divfn)(cp,k,80,entropy,&rng,ga,a));C(!L(f,ccec_diversify_pub,divfn)(cp,k,80,entropy,&rng,gb,b));C(!memcmp(ga+16,gb+16,24*cp->n)&&!memcmp(a+16,b+16,24*cp->n));
typedef size_t(*szfn)(const void*,const void*,unsigned);typedef void*(*derfn)(const void*,const void*,unsigned,size_t,void*);typedef int(*derinfn)(const struct cczp*,size_t,const void*,unsigned*,void*,void*);for(unsigned flag=0;flag<=4;flag+=4){size_t n=L(h,ccec_der_export_diversified_pub_size,szfn)(ga,a,flag);C(n==L(f,ccec_der_export_diversified_pub_size,szfn)(ga,a,flag));unsigned char x[320],y[320];C(L(h,ccec_der_export_diversified_pub,derfn)(ga,a,flag,n,x)==x);C(L(f,ccec_der_export_diversified_pub,derfn)(ga,a,flag,n,y)==y);C(!memcmp(x,y,n));unsigned hf=9,ff=9;C(!L(h,ccec_der_import_diversified_pub,derinfn)(cp,n,x,&hf,ga,a));C(!L(f,ccec_der_import_diversified_pub,derinfn)(cp,n,x,&ff,gb,b));C(hf==ff&&!memcmp(ga+16,gb+16,24*cp->n)&&!memcmp(a+16,b+16,24*cp->n));}}
printf("ECC extra: %d checks passed\n",checks);}
