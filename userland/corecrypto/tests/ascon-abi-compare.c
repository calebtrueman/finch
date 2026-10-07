/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ascon.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do {if(!(x)){fprintf(stderr,"line %d failed: %s\n",__LINE__,#x);exit(1);}}while(0)
int main(int argc,char **argv) {
    CHECK(argc==2);void *lib[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL)};CHECK(lib[0]&&lib[1]);
    const struct ccascon_info *m[2];const struct ccascon_cmac_info *a[2];for(int j=0;j<2;j++){m[j]=dlsym(lib[j],"ccascon_ascon128a_ref");a[j]=dlsym(lib[j],"ccascon_ascon128a_cmac_ref");CHECK(m[j]&&a[j]);Dl_info info;CHECK(dladdr(m[j],&info));if(j)CHECK(strstr(info.dli_fname,argv[1]));}
    CHECK(!memcmp(m[0],m[1],24));CHECK(!memcmp(a[0],a[1],24));
    unsigned char key[16],nonce[16],aad[64],in[128];for(size_t i=0;i<16;i++)key[i]=i*7,nonce[i]=i*13;for(size_t i=0;i<64;i++)aad[i]=i*3;for(size_t i=0;i<128;i++)in[i]=i*11;
    for(size_t n=0;n<128;n++)for(size_t an=0;an<48;an++) {
        _Alignas(16) unsigned char c[2][64],out[2][144],t[2][32],p[2][144];memset(c,0xa5,sizeof(c));memset(out,0xb5,sizeof(out));memset(t,0xc7,sizeof(t));
        for(int j=0;j<2;j++)CHECK(!m[j]->init(c[j],an,aad,nonce,key));CHECK(!memcmp(c[0],c[1],64));
        for(int j=0;j<2;j++)CHECK(!m[j]->encrypt(c[j],out[j],t[j],n,in,key));CHECK(!memcmp(c[0],c[1],64));CHECK(!memcmp(out[0],out[1],144));CHECK(!memcmp(t[0],t[1],32));
        for(int j=0;j<2;j++){CHECK(!m[j]->init(c[j],an,aad,nonce,key));CHECK(!m[1-j]->decrypt(c[j],p[j],t[j],n,out[j],key));CHECK(!memcmp(p[j],in,n));}CHECK(!memcmp(c[0],c[1],64));
        for(int j=0;j<2;j++){CHECK(!m[j]->init(c[j],an,aad,nonce,key));t[j][0]^=1;CHECK(m[j]->decrypt(c[j],p[j],t[j],n,out[j],key)==-2);for(size_t i=0;i<n;i++)CHECK(p[j][i]==0);}CHECK(!memcmp(c[0],c[1],64));
        for(int j=0;j<2;j++){CHECK(!a[j]->init(c[j],an,aad,nonce,key));CHECK(!a[j]->process(c[j],n/2,in));CHECK(!a[j]->process(c[j],n-n/2,in+n/2));CHECK(!a[j]->tag(c[j],t[j],key));CHECK(!a[1-j]->verify(c[j],16,t[j],key));CHECK(a[j]->verify(c[j],0,t[j],key)==a[1-j]->verify(c[j],0,t[j],key));}CHECK(!memcmp(c[0],c[1],64));CHECK(!memcmp(t[0],t[1],32));
    }
    puts("ASCON: host bytes, full state, mixed calls, partial CMAC calls and damaged tags match");return 0;
}
