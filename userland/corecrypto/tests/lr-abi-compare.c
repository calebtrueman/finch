/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccmode.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"line %d failed: %s\n",__LINE__,#x);exit(1);}}while(0)
int main(int argc,char**argv){CHECK(argc==2);void*lib[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL)};CHECK(lib[0]&&lib[1]);int(*init[2])(void*,const struct ccmode_ecb*,const void*,size_t,size_t);size_t(*size[2])(const void*);int(*enc[2])(const void*,size_t,void*,const void*),(*dec[2])(const void*,size_t,void*,const void*);for(int j=0;j<2;j++){init[j]=dlsym(lib[j],"cclr_aes_init");size[j]=dlsym(lib[j],"cclr_block_nbytes");enc[j]=dlsym(lib[j],"cclr_encrypt_block");dec[j]=dlsym(lib[j],"cclr_decrypt_block");Dl_info info;CHECK(dladdr((void*)init[j],&info));if(j)CHECK(strstr(info.dli_fname,argv[1]));}
 const struct ccmode_ecb*e=((const struct ccmode_ecb*(*)(void))dlsym(lib[0],"ccaes_ecb_encrypt_mode"))();unsigned char key[32],in[32],keyctx[256];for(size_t i=0;i<32;i++)key[i]=i*13,in[i]=i*7;CHECK(!e->init(e,keyctx,32,key));
 for(size_t bits=0;bits<140;bits++)for(size_t rounds=0;rounds<13;rounds++){unsigned char ctx[2][64],out[2][32],plain[32];memset(ctx,0xa5,sizeof(ctx));int r[2];for(int j=0;j<2;j++)r[j]=init[j](ctx[j],e,keyctx,bits,rounds);CHECK(r[0]==r[1]);CHECK(!memcmp(ctx[0]+8,ctx[1]+8,56));if(r[0])continue;CHECK(size[0](ctx[0])==size[1](ctx[1]));for(size_t n=0;n<20;n++){memset(out,0xb5,sizeof(out));for(int j=0;j<2;j++)r[j]=enc[1-j](ctx[j],n,out[j],in);CHECK(r[0]==r[1]);CHECK(!memcmp(out[0],out[1],32));if(!r[0]){CHECK(!dec[0](ctx[1],n,plain,out[0]));CHECK(!memcmp(in,plain,n));CHECK(!dec[1](ctx[0],n,plain,out[1]));CHECK(!memcmp(in,plain,n));}}}
 puts("LR: host ciphertext/state, cross-use, all sizes/rounds, guards and round trips match");return 0;}
