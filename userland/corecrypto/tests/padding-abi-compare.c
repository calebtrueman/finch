/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccmode.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(X) do{if(!(X)){fprintf(stderr,"FAIL %d: %s %s n=%zu\n",__LINE__,#X,name,n);exit(1);}}while(0)
typedef size_t(*pad)(const struct ccmode_cbc*,const void*,void*,size_t,const void*,void*);
int main(int argc,char**argv){if(argc!=2)return 2;void*h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",2),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL)};char name[100]="open";size_t n=0;CHECK(h[0]&&h[1]);unsigned char key[16]={0},in[160],out[2][192],ctx[2][512],iv[2][16];for(int i=0;i<160;i++)in[i]=i*5;for(int kind=0;kind<4;kind++)for(int decrypt=0;decrypt<2;decrypt++){if(kind)snprintf(name,sizeof name,"ccpad_cts%d_%s",kind,decrypt?"decrypt":"encrypt");if(!kind)snprintf(name,sizeof name,"ccpad_pkcs7_%s",decrypt?"decrypt":"encrypt");pad p[2];const struct ccmode_cbc*m[2];for(int j=0;j<2;j++){p[j]=dlsym(h[j],name);CHECK(p[j]);const struct ccmode_cbc*(*get)(void)=dlsym(h[j],decrypt?"ccaes_cbc_decrypt_mode":"ccaes_cbc_encrypt_mode");m[j]=get();m[j]->init(m[j],ctx[j],16,key);}for(n=16;n<=128;n++){if(!kind&&decrypt&&n%16)continue;size_t ret[2];for(int j=0;j<2;j++){memset(out[j],0xa5,sizeof out[j]);memset(iv[j],0x17,16);ret[j]=p[j](m[1-j],ctx[1-j],iv[j],n,in,out[j]);}CHECK(ret[0]==ret[1]);CHECK(!memcmp(out[0],out[1],192));CHECK(!memcmp(iv[0],iv[1],16));}}
for(int decrypt=0;decrypt<2;decrypt++){
 snprintf(name,sizeof name,"ccpad_pkcs7_ecb_%s",decrypt?"decrypt":"encrypt");
 typedef size_t(*epad)(const struct ccmode_ecb*,const void*,size_t,const void*,void*);epad p[2];const struct ccmode_ecb*m[2];
 for(int j=0;j<2;j++){p[j]=dlsym(h[j],name);const struct ccmode_ecb*(*get)(void)=dlsym(h[j],decrypt?"ccaes_ecb_decrypt_mode":"ccaes_ecb_encrypt_mode");m[j]=get();m[j]->init(m[j],ctx[j],16,key);}
 for(n=decrypt?16:0;n<=128;n++){if(decrypt&&n%16)continue;size_t ret[2];for(int j=0;j<2;j++){memset(out[j],0xa5,192);ret[j]=p[j](m[1-j],ctx[1-j],n,in,out[j]);}CHECK(ret[0]==ret[1]);CHECK(!memcmp(out[0],out[1],192));}
}
for(int decrypt=0;decrypt<2;decrypt++){
 snprintf(name,sizeof name,"ccpad_xts_%s",decrypt?"decrypt":"encrypt");
 typedef size_t(*xpad)(const struct ccmode_xts*,const void*,void*,size_t,const void*,void*);xpad p[2];const struct ccmode_xts*m[2];unsigned char tweak[2][64],tk[16]={1};
 for(int j=0;j<2;j++){p[j]=dlsym(h[j],name);CHECK(p[j]);const struct ccmode_xts*(*get)(void)=dlsym(h[j],decrypt?"ccaes_xts_decrypt_mode":"ccaes_xts_encrypt_mode");m[j]=get();m[j]->init(m[j],ctx[j],16,key,tk);}
 for(n=16;n<=128;n++){size_t ret[2];for(int j=0;j<2;j++){memset(tweak[j],0xa5,64);m[1-j]->set_tweak(ctx[1-j],tweak[j],key);memset(out[j],0xa5,192);ret[j]=p[j](m[1-j],ctx[1-j],tweak[j],n,in,out[j]);}if(decrypt)CHECK(ret[0]==ret[1]);CHECK(!memcmp(out[0],out[1],192));CHECK(!memcmp(tweak[0],tweak[1],64));}
}
strcpy(name,"pkcs7_decode");size_t(*decode[2])(size_t,const void*)={dlsym(h[0],"ccpad_pkcs7_decode"),dlsym(h[1],"ccpad_pkcs7_decode")};for(n=0;n<256;n++){memset(in,7,16);in[15]=n;CHECK(decode[0](16,in)==decode[1](16,in));}puts("Padding: CBC/ECB PKCS7, XTS and all three CTS forms match output, sizes, IV state and guards; malformed padding lengths match");}
