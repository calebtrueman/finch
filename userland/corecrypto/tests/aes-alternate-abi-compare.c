/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccmode.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do {if(!(x)){fprintf(stderr,"line %d failed: %s\n",__LINE__,#x);exit(1);}}while(0)
static void same(const unsigned char*a,const unsigned char*b,size_t n){for(size_t i=0;i<n;i++)if(a[i]!=b[i]){fprintf(stderr,"byte %zu: %02x vs %02x\n",i,a[i],b[i]);exit(1);}}
int main(int argc,char**argv){CHECK(argc==2);void*lib[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL)};CHECK(lib[0]&&lib[1]);unsigned char key[32],in[128],iv[16];for(size_t i=0;i<32;i++)key[i]=i*13+7;for(size_t i=0;i<128;i++)in[i]=i*11;for(size_t i=0;i<16;i++)iv[i]=i*7;
 const char*names[]={"ccaes_ltc_ecb_encrypt_mode","ccaes_ltc_ecb_decrypt_mode","ccaes_gladman_cbc_encrypt_mode","ccaes_gladman_cbc_decrypt_mode","ccaes_arm_cbc_encrypt_mode","ccaes_arm_cbc_decrypt_mode"};
 for(size_t s=0;s<6;s++){const struct ccmode_ecb *e[2];const struct ccmode_cbc*b[2];for(int j=0;j<2;j++){e[j]=dlsym(lib[j],names[s]);b[j]=(const void*)e[j];CHECK(e[j]);Dl_info info;CHECK(dladdr(e[j],&info));if(j)CHECK(strstr(info.dli_fname,argv[1]));}CHECK(e[0]->size==e[1]->size);for(size_t kn=0;kn<=256;kn++){
 _Alignas(16) unsigned char c[2][1024],v[2][16],out[2][128];memset(c,0xa5,sizeof(c));int r[2];for(int j=0;j<2;j++)r[j]=e[j]->init(e[j],c[j],kn,key);if(r[0]!=r[1]){fprintf(stderr,"%s kn%zu returns %d %d\n",names[s],kn,r[0],r[1]);return 1;}same(c[0],c[1],1024);if(r[0])continue;
 for(int j=0;j<2;j++){memcpy(v[j],iv,16);if(s<2)CHECK(!e[1-j]->ecb(c[j],8,in,out[j]));else CHECK(!b[1-j]->cbc(c[j],v[j],8,in,out[j]));}same(out[0],out[1],128);same(v[0],v[1],16);same(c[0],c[1],1024);
 }}
 int(*unwind[2])(size_t,const void*,void*);for(int j=0;j<2;j++)unwind[j]=dlsym(lib[j],"ccaes_unwind");for(size_t n=0;n<64;n++){unsigned char o[2][48];memset(o,0xa5,sizeof(o));CHECK(unwind[0](n,key,o[0])==unwind[1](n,key,o[1]));same(o[0],o[1],48);}
 const char*aliases[]={"ccaes_arm_cfb_encrypt_mode","ccaes_arm_cfb_decrypt_mode","ccaes_arm_ofb_crypt_mode","ccaes_arm_xts_encrypt_mode","ccaes_arm_xts_decrypt_mode"};for(size_t i=0;i<5;i++){void*p=dlsym(lib[1],aliases[i]);CHECK(p);Dl_info info;CHECK(dladdr(p,&info));CHECK(strstr(info.dli_fname,argv[1]));}
 puts("Alternate AES: host key bytes, shared contexts, ciphertext, IVs, errors and unwind match");return 0;}
