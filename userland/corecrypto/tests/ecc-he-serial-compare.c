/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "../abi/cche.h"
#include "he-symbol-owner.h"
static unsigned tests;
#define CHECK(x) do{tests++;if(!(x)){fprintf(stderr,"line%d %s\n",__LINE__,#x);exit(1);}}while(0)
int main(int argc,char**argv){void*h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",2),dlopen(argc>1?argv[1]:"/tmp/ecc-he-test.dylib",2)};CHECK(h[0]&&h[1]);finch_test_set_local(h[1],argc>1?argv[1]:"/tmp/ecc-he-test.dylib");size_t(*sz)(unsigned)=dlsym(h[0],"cche_param_ctx_sizeof");int(*init)(void*,unsigned,unsigned)=dlsym(h[0],"cche_param_ctx_init");for(unsigned id=0;id<17;id++){struct he_params*p=calloc(1,sz(id));CHECK(init(p,1,id)==0);for(unsigned l=1;l<=p->l;l++){size_t cs=24+2*(8+8*(size_t)p->n*l);struct he_cipher*c=calloc(1,cs),*d=calloc(1,cs);c->params=p;c->npolys=2;c->correction=1;struct he_ring*r=(void*)((char*)p+40+8*p->l);while(r->l!=l)r=r->next;for(unsigned pol=0;pol<2;pol++){struct he_poly*x=(void*)(c->data+pol*(8+8*(size_t)p->n*l));x->ctx=r;for(unsigned i=0;i<p->n*l;i++)x->data[i]=(i+1)%p->q[i/p->n];}for(unsigned skipOn=0;skipOn<=(l==1);skipOn++){uint32_t skip[2]={skipOn?p->skip[0]:0,skipOn?p->skip[1]:0};size_t(*size[2])(void*,void*);int(*ser[2])(size_t,void*,void*,void*);int(*des[2])(void*,size_t,void*,void*,unsigned,unsigned,uint64_t,void*);void*b[2];size_t n[2];for(int i=0;i<2;i++){size[i]=dlsym(h[i],"cche_serialize_ciphertext_coeff_nbytes");ser[i]=dlsym(h[i],"cche_serialize_ciphertext_coeff");des[i]=dlsym(h[i],"cche_deserialize_ciphertext_coeff");n[i]=size[i](c,skip);b[i]=calloc(1,n[i]);CHECK(ser[i](n[i],b[i],c,skip)==0);}CHECK(n[0]==n[1]);CHECK(!memcmp(b[0],b[1],n[0]));for(int i=0;i<2;i++){int rc=des[i](d,n[0],b[0],p,l,2,1,skip);if(rc)fprintf(stderr,"id%u l%u i%d rc%d\n",id,l,i,rc);CHECK(rc==0);}free(b[0]);free(b[1]);}free(c);free(d);}free(p);}printf("HE serialization: %u checks passed\n",tests);}
