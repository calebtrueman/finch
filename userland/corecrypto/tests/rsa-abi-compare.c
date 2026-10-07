/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccrsa.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define LOAD(ret,name,args) ret(*h_##name)args=dlsym(host,#name);ret(*f_##name)args=dlsym(finch,#name);if(!h_##name||!f_##name){fprintf(stderr,"missing %s\n",#name);return 2;}
static unsigned checks;static int failures;
#define CHECK(x) do{checks++;if(!(x)){failures++;fprintf(stderr,"line %d: %s\n",__LINE__,#x);}}while(0)
static int random_(struct ccrng_state*r,size_t n,void*p){(void)r;arc4random_buf(p,n);return 0;}
static int sequence(struct ccrng_state*r,size_t n,void*p){(void)r;memset(p,0x59,n);return 0;}
int main(int argc,char**argv){void*host=dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),*finch=dlopen(argc>1?argv[1]:"build/userland/corecrypto/rsa-test.dylib",RTLD_NOW|RTLD_LOCAL);if(!host||!finch){puts(dlerror());return 2;}
 LOAD(int,ccrsa_generate_key,(size_t,ccrsa_ctx*,size_t,const void*,struct ccrng_state*));
 LOAD(int,ccrsa_import_priv,(ccrsa_ctx*,size_t,const void*));LOAD(int,ccrsa_import_pub,(ccrsa_ctx*,size_t,const void*));
 LOAD(int,ccrsa_export_priv,(const ccrsa_ctx*,size_t,void*));LOAD(int,ccrsa_export_pub,(const ccrsa_ctx*,size_t,void*));
 LOAD(size_t,ccrsa_export_priv_size,(const ccrsa_ctx*));LOAD(size_t,ccrsa_export_pub_size,(const ccrsa_ctx*));
 LOAD(size_t,ccrsa_import_priv_n,(size_t,const void*));LOAD(size_t,ccrsa_import_pub_n,(size_t,const void*));
 LOAD(int,ccrsa_make_pub,(ccrsa_ctx*,size_t,const void*,size_t,const void*));
 LOAD(int,ccrsa_make_priv,(ccrsa_ctx*,size_t,const void*,size_t,const void*,size_t,const void*));
 LOAD(int,ccrsa_recover_priv,(ccrsa_ctx*,size_t,const void*,size_t,const void*,size_t,const void*,struct ccrng_state*));
 LOAD(int,ccrsa_pub_crypt,(const ccrsa_ctx*,cc_unit*,const cc_unit*));LOAD(int,ccrsa_priv_crypt,(const ccrsa_ctx*,cc_unit*,const cc_unit*));
 LOAD(int,ccrsa_get_pubkey_components,(const ccrsa_ctx*,void*,size_t*,void*,size_t*));
 LOAD(int,ccrsa_get_fullkey_components,(const ccrsa_ctx*,void*,size_t*,void*,size_t*,void*,size_t*,void*,size_t*));
 LOAD(int,ccrsa_sign_pkcs1v15,(const ccrsa_ctx*,const void*,size_t,const void*,size_t*,void*));
 LOAD(int,ccrsa_verify_pkcs1v15_digest,(const ccrsa_ctx*,const void*,size_t,const void*,size_t,const void*,void*));
 LOAD(int,ccrsa_sign_pss,(const ccrsa_ctx*,const struct ccdigest_info*,const struct ccdigest_info*,size_t,struct ccrng_state*,size_t,const void*,size_t*,void*));
 LOAD(int,ccrsa_verify_pss_digest,(const ccrsa_ctx*,const struct ccdigest_info*,const struct ccdigest_info*,size_t,const void*,size_t,const void*,size_t,void*));
 LOAD(int,ccrsa_encrypt_eme_pkcs1v15,(const ccrsa_ctx*,struct ccrng_state*,size_t*,void*,size_t,const void*));
 LOAD(int,ccrsa_decrypt_eme_pkcs1v15,(const ccrsa_ctx*,size_t*,void*,size_t,const void*));
 LOAD(int,ccrsa_encrypt_oaep,(const ccrsa_ctx*,const struct ccdigest_info*,struct ccrng_state*,size_t*,void*,size_t,const void*,size_t,const void*));
 LOAD(int,ccrsa_decrypt_oaep,(const ccrsa_ctx*,const struct ccdigest_info*,size_t*,void*,size_t,const void*,size_t,const void*));
 LOAD(const struct ccdigest_info*,ccsha256_di,(void));
 LOAD(int,ccrsa_emsa_pkcs1v15_encode,(size_t,void*,size_t,const void*,const void*));LOAD(int,ccrsa_emsa_pkcs1v15_verify,(size_t,const void*,size_t,const void*,const void*));
 const struct ccdigest_info*hd=h_ccsha256_di(),*fd=f_ccsha256_di();struct ccrng_state rng={random_},seq={sequence};unsigned char exponent[]={1,0,1};
 unsigned char encoded[128],expected[128],digest[32]={1};for(unsigned has_oid=0;has_oid<2;has_oid++){const void*oid=has_oid?hd->oid:NULL;CHECK(h_ccrsa_emsa_pkcs1v15_encode(128,expected,32,digest,oid)==f_ccrsa_emsa_pkcs1v15_encode(128,encoded,32,digest,oid));CHECK(!memcmp(expected,encoded,128));for(size_t pos=0;pos<128;pos++)for(unsigned change=1;change<=255;change=change==1?2:change==2?255:256){encoded[pos]^=change;CHECK(h_ccrsa_emsa_pkcs1v15_verify(128,encoded,32,digest,oid)==f_ccrsa_emsa_pkcs1v15_verify(128,encoded,32,digest,oid));encoded[pos]^=change;}}
 for(int bits=1024;bits<=2048;bits+=1024){
 cc_unit hk[2048]={0},fk[2048]={0},other[2048]={0};hk[0]=(bits+63)/64;fk[0]=hk[0];ccrsa_ctx*h=(void*)hk,*f=(void*)fk,*o=(void*)other;
 CHECK(h_ccrsa_generate_key(bits,h,3,exponent,&rng)==0);size_t n=h_ccrsa_export_priv_size(h);unsigned char der[8192],der2[8192];CHECK(h_ccrsa_export_priv(h,n,der)==0);CHECK(f_ccrsa_import_priv_n(n,der)==h_ccrsa_import_priv_n(n,der));CHECK(f_ccrsa_import_priv(f,n,der)==0);CHECK(f_ccrsa_export_priv_size(f)==n);CHECK(f_ccrsa_export_priv(f,n,der2)==0);CHECK(!memcmp(der,der2,n));
 size_t skip1=2,skip2=(32+32*h->n)/8+2,skip3=skip2+4+2*finch_rsa_p(h)->n;
 size_t words=((char*)(finch_rsa_qinv(h)+finch_rsa_p(h)->n)-(char*)h)/8;
 for(size_t i=0;i<words;i++)if(i!=skip1&&i!=skip2&&i!=skip3)CHECK(hk[i]==fk[i]);
 size_t pn=h_ccrsa_export_pub_size(h);CHECK(f_ccrsa_export_pub_size(f)==pn);CHECK(h_ccrsa_export_pub(h,pn,der)==0);CHECK(f_ccrsa_export_pub(f,pn,der2)==0);CHECK(!memcmp(der,der2,pn));o->n=h->n;CHECK(h_ccrsa_import_pub(o,pn,der2)==0);CHECK(f_ccrsa_import_pub_n(pn,der)==h->n);
 cc_unit in[64]={42},ho[64],fo[64];CHECK(h_ccrsa_pub_crypt(h,ho,in)==0);CHECK(f_ccrsa_pub_crypt(f,fo,in)==0);CHECK(!memcmp(ho,fo,h->n*8));CHECK(h_ccrsa_pub_crypt(f,fo,in)==0);CHECK(!memcmp(ho,fo,h->n*8));CHECK(f_ccrsa_pub_crypt(h,fo,in)==0);CHECK(!memcmp(ho,fo,h->n*8));CHECK(h_ccrsa_priv_crypt(h,ho,in)==0);CHECK(f_ccrsa_priv_crypt(f,fo,in)==0);CHECK(!memcmp(ho,fo,h->n*8));CHECK(h_ccrsa_priv_crypt(f,fo,in)==0);CHECK(!memcmp(ho,fo,h->n*8));
 unsigned char nn[512],ee[512],dd[512],pp[512],qq[512];size_t nl=512,el=512,dl=512,pl=512,ql=512;CHECK(f_ccrsa_get_pubkey_components(f,nn,&nl,ee,&el)==0);CHECK(f_ccrsa_get_fullkey_components(f,nn,&nl,dd,&dl,pp,&pl,qq,&ql)==0);o->n=h->n;CHECK(f_ccrsa_make_priv(o,el,ee,pl,pp,ql,qq)==0);CHECK(f_ccrsa_export_priv_size(o)==n);CHECK(f_ccrsa_export_priv(o,n,der2)==0);CHECK(h_ccrsa_export_priv(h,n,der)==0);CHECK(!memcmp(der,der2,n));CHECK(f_ccrsa_recover_priv(o,nl,nn,el,ee,dl,dd,&rng)==0);CHECK(f_ccrsa_export_priv(o,n,der2)==0);CHECK(!memcmp(der,der2,n));
 unsigned char hash[32]={1,2,3},hs[512],fs[512],hc[16],fc[16];size_t hs_n=512,fs_n=512;
 CHECK(h_ccrsa_sign_pkcs1v15(h,hd->oid,32,hash,&hs_n,hs)==0);CHECK(f_ccrsa_sign_pkcs1v15(f,fd->oid,32,hash,&fs_n,fs)==0);CHECK(hs_n==fs_n&&!memcmp(hs,fs,hs_n));int hr=h_ccrsa_verify_pkcs1v15_digest(h,hd->oid,32,hash,fs_n,fs,hc),fr=f_ccrsa_verify_pkcs1v15_digest(f,fd->oid,32,hash,hs_n,hs,fc);if(hr!=fr)fprintf(stderr,"verify15 host=%d finch=%d\n",hr,fr);CHECK(hr==fr);CHECK(!memcmp(hc,fc,16));hs[10]^=1;hr=h_ccrsa_verify_pkcs1v15_digest(h,hd->oid,32,hash,hs_n,hs,hc);fr=f_ccrsa_verify_pkcs1v15_digest(f,fd->oid,32,hash,hs_n,hs,fc);if(hr!=fr)fprintf(stderr,"bad verify15 host=%d finch=%d\n",hr,fr);CHECK(hr==fr);CHECK(!memcmp(hc,fc,16));
 hs_n=fs_n=512;CHECK(h_ccrsa_sign_pss(h,hd,hd,32,&seq,32,hash,&hs_n,hs)==0);CHECK(f_ccrsa_sign_pss(f,fd,fd,32,&seq,32,hash,&fs_n,fs)==0);CHECK(hs_n==fs_n&&!memcmp(hs,fs,hs_n));hr=h_ccrsa_verify_pss_digest(h,hd,hd,32,hash,fs_n,fs,32,hc);fr=f_ccrsa_verify_pss_digest(f,fd,fd,32,hash,hs_n,hs,32,fc);if(hr!=fr)fprintf(stderr,"verifypss host=%d finch=%d\n",hr,fr);CHECK(hr==fr);CHECK(!memcmp(hc,fc,16));
 hs_n=fs_n=512;CHECK(h_ccrsa_encrypt_eme_pkcs1v15(h,&seq,&hs_n,hs,5,"hello")==0);CHECK(f_ccrsa_encrypt_eme_pkcs1v15(f,&seq,&fs_n,fs,5,"hello")==0);CHECK(hs_n==fs_n&&!memcmp(hs,fs,hs_n));size_t ml=512;unsigned char msg[512];CHECK(h_ccrsa_decrypt_eme_pkcs1v15(f,&ml,msg,fs_n,fs)==0);CHECK(ml==5&&!memcmp(msg,"hello",5));ml=512;CHECK(f_ccrsa_decrypt_eme_pkcs1v15(h,&ml,msg,hs_n,hs)==0);CHECK(ml==5&&!memcmp(msg,"hello",5));
 for(unsigned bad=0;bad<8;bad++){unsigned char badc[512]={0},hm[512],fm[512];badc[hs_n-1]=(unsigned char)bad;size_t hn=512,fn=512;int a=h_ccrsa_decrypt_eme_pkcs1v15(h,&hn,hm,hs_n,badc),b=f_ccrsa_decrypt_eme_pkcs1v15(f,&fn,fm,hs_n,badc);CHECK(a==b);CHECK(hn==fn);CHECK(!memcmp(hm,fm,hn));}
 hs_n=fs_n=512;CHECK(h_ccrsa_encrypt_oaep(h,hd,&seq,&hs_n,hs,5,"hello",3,"tag")==0);CHECK(f_ccrsa_encrypt_oaep(f,fd,&seq,&fs_n,fs,5,"hello",3,"tag")==0);CHECK(hs_n==fs_n&&!memcmp(hs,fs,hs_n));ml=512;CHECK(h_ccrsa_decrypt_oaep(f,hd,&ml,msg,fs_n,fs,3,"tag")==0);CHECK(ml==5&&!memcmp(msg,"hello",5));ml=512;CHECK(f_ccrsa_decrypt_oaep(h,fd,&ml,msg,hs_n,hs,3,"tag")==0);CHECK(ml==5&&!memcmp(msg,"hello",5));
 CHECK(f_ccrsa_generate_key(bits,o,3,exponent,&rng)==0);CHECK(h_ccrsa_priv_crypt(o,ho,in)==0);CHECK(f_ccrsa_priv_crypt(o,fo,in)==0);CHECK(!memcmp(ho,fo,o->n*8));
 }
 printf("RSA ABI: %u checks, %d failures\n",checks,failures);return failures?1:0;}
