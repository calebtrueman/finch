/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccsrp.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int checks,fail;
#define CK(x) do{checks++;if(!(x)){fail++;fprintf(stderr,"line %d: %s (group %u option %u)\n",__LINE__,#x,group,opt);}}while(0)
#define LOAD(ret,name,args) ret(*h_##name)args=dlsym(h,#name);ret(*f_##name)args=dlsym(f,#name);if(!h_##name||!f_##name){puts(#name);return 2;}
static int random_(struct ccrng_state*r,size_t n,void*p){(void)r;memset(p,0x59,n);return 0;}
int main(int argc,char**argv){void*h=dlopen("/usr/lib/system/libcorecrypto.dylib",2),*f=dlopen(argc>1?argv[1]:"build/userland/corecrypto/srp-test.dylib",2);if(!h||!f){puts(dlerror());return 2;}
 LOAD(int,ccsrp_ctx_init_option,(struct ccsrp_ctx*,const struct ccdigest_info*,const struct cczp*,unsigned,struct ccrng_state*));
 LOAD(int,ccsrp_generate_verifier,(struct ccsrp_ctx*,const char*,size_t,const void*,size_t,const void*,void*));
 LOAD(int,ccsrp_client_start_authentication,(struct ccsrp_ctx*,struct ccrng_state*,void*));
 LOAD(int,ccsrp_server_start_authentication,(struct ccsrp_ctx*,struct ccrng_state*,const char*,size_t,const void*,const void*,const void*,void*));
 LOAD(int,ccsrp_client_process_challenge,(struct ccsrp_ctx*,const char*,size_t,const void*,size_t,const void*,const void*,void*));
 LOAD(bool,ccsrp_server_verify_session,(struct ccsrp_ctx*,const void*,void*));LOAD(bool,ccsrp_client_verify_session,(struct ccsrp_ctx*,const void*));
 LOAD(int,ccsrp_client_set_noUsernameInX,(struct ccsrp_ctx*,int));LOAD(int,ccsrp_server_compute_session,(struct ccsrp_ctx*,const char*,size_t,const void*,const void*));
 LOAD(const void*,ccsrp_get_session_key,(const struct ccsrp_ctx*,size_t*));
 const char*digests[]={"ccsha1_di","ccsha256_di","ccsha512_di"};for(unsigned digest_i=0;digest_i<3;digest_i++){const struct ccdigest_info*(*hd)(void)=dlsym(h,digests[digest_i]),*(*fd)(void)=dlsym(f,digests[digest_i]);unsigned bits[]={1024,2048,3072,4096,8192},options[]={0,1,2,8,9,10,64,65,66,128,129,130,192,193,194};struct ccrng_state rng={random_};
 size_t hashsize=hd()->output_size;for(unsigned group=0;group<5;group++){char name[80];sprintf(name,"ccsrp_gp_rfc5054_%u",bits[group]);const struct cczp*(*hg)(void)=dlsym(h,name),*(*fg)(void)=dlsym(f,name);size_t n=bits[group]/8;for(unsigned oi=0;oi<(group>1?1:15);oi++){unsigned opt=options[oi];const struct cczp*gp=fg();CK(gp->n==hg()->n);CK(!memcmp(gp->data,hg()->data,32*gp->n+16));
 unsigned char hc[5000],fc[5000],hs[5000],fs[5000];struct ccsrp_ctx*ch=(void*)hc,*cf=(void*)fc,*sh=(void*)hs,*sf=(void*)fs;unsigned char hv[1024],fv[1024],ha[1024],fa[1024],hb[1024],fb[1024],hm[64],fm[64],hh[64],fh[64],salt[16]={1,2,3};
 CK(h_ccsrp_ctx_init_option(ch,hd(),hg(),opt,&rng)==f_ccsrp_ctx_init_option(cf,fd(),fg(),opt,&rng));CK(!memcmp(hc+24,fc+24,48+4*(n+hashsize)-24));CK(h_ccsrp_ctx_init_option(sh,hd(),hg(),opt,&rng)==f_ccsrp_ctx_init_option(sf,fd(),fg(),opt,&rng));
 unsigned char zeros[1024]={0};CK(h_ccsrp_server_compute_session(sh,"alice",16,salt,zeros)==f_ccsrp_server_compute_session(sf,"alice",16,salt,zeros));size_t empty_h,empty_f;CK(h_ccsrp_get_session_key(ch,&empty_h)==NULL);CK(f_ccsrp_get_session_key(cf,&empty_f)==NULL);CK(empty_h==empty_f);CK(h_ccsrp_client_set_noUsernameInX(ch,digest_i&1)==f_ccsrp_client_set_noUsernameInX(cf,digest_i&1));
 int a=h_ccsrp_generate_verifier(ch,"alice",8,"password",16,salt,hv),b=f_ccsrp_generate_verifier(cf,"alice",8,"password",16,salt,fv);CK(a==b);CK(!memcmp(hv,fv,n));
 a=h_ccsrp_client_start_authentication(ch,&rng,ha);b=f_ccsrp_client_start_authentication(cf,&rng,fa);CK(a==b);CK(!memcmp(ha,fa,n));CK(!memcmp(ch->data,cf->data,n*2));
 a=h_ccsrp_server_start_authentication(sh,&rng,"alice",16,salt,hv,ha,hb);b=f_ccsrp_server_start_authentication(sf,&rng,"alice",16,salt,fv,fa,fb);if(a!=b)fprintf(stderr,"server %d %d\n",a,b);CK(a==b);CK(!memcmp(hb,fb,n));CK(!memcmp(hs+24,fs+24,32+4*(n+hashsize)-24));
 a=h_ccsrp_client_process_challenge(ch,"alice",8,"password",16,salt,hb,hm);b=f_ccsrp_client_process_challenge(cf,"alice",8,"password",16,salt,fb,fm);if(a!=b)fprintf(stderr,"client %d %d\n",a,b);CK(a==b);CK(!memcmp(hm,fm,hashsize));CK(!memcmp(hc+24,fc+24,32+4*(n+hashsize)-24));
 CK(h_ccsrp_server_compute_session(sh,"alice",16,salt,zeros)==f_ccsrp_server_compute_session(sf,"alice",16,salt,zeros));CK(h_ccsrp_client_process_challenge(ch,"alice",8,"password",16,salt,zeros,hm)==f_ccsrp_client_process_challenge(cf,"alice",8,"password",16,salt,zeros,fm));
 CK(h_ccsrp_server_verify_session(sh,fm,hh));CK(f_ccsrp_server_verify_session(sf,hm,fh));CK(!memcmp(hh,fh,hashsize));CK(h_ccsrp_client_verify_session(ch,fh));CK(f_ccsrp_client_verify_session(cf,hh));size_t hn,fn;const void*hk=h_ccsrp_get_session_key(ch,&hn),*fk=f_ccsrp_get_session_key(cf,&fn);CK(hn==fn);CK(hk&&fk&&!memcmp(hk,fk,hn));hm[0]^=1;CK(!h_ccsrp_server_verify_session(sh,hm,hh));CK(!f_ccsrp_server_verify_session(sf,hm,fh));
 }}}printf("SRP ABI: %d checks, %d failures\n",checks,fail);return !!fail;}
