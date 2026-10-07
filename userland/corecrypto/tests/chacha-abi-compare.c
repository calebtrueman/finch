/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/chacha.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks,failures;
static void same(const char*n,const void*a,const void*b,size_t z){checks++;if(memcmp(a,b,z)&&failures++<20){size_t j=0;while(j<z&&((const unsigned char*)a)[j]==((const unsigned char*)b)[j])j++;fprintf(stderr,"%s differs at %zu (%02x/%02x)\n",n,j,((const unsigned char*)a)[j],((const unsigned char*)b)[j]);}}
static void num(const char*n,int a,int b){same(n,&a,&b,sizeof(a));}
static void *sym(void*h,const char*n){void*p=dlsym(h,n);if(!p){fprintf(stderr,"%s\n",dlerror());exit(2);}return p;}
#define CHACHA(X) X(ccchacha20_init) X(ccchacha20_setnonce) X(ccchacha20_setcounter) X(ccchacha20_reset) X(ccchacha20_final) X(ccchacha20_update) X(ccchacha20)
#define POLY(X) X(ccpoly1305_init) X(ccpoly1305_update) X(ccpoly1305_final) X(ccpoly1305)
#define AEAD(X) X(ccchacha20poly1305_info) X(ccchacha20poly1305_init) X(ccchacha20poly1305_reset) X(ccchacha20poly1305_setnonce) X(ccchacha20poly1305_incnonce) X(ccchacha20poly1305_aad) X(ccchacha20poly1305_encrypt) X(ccchacha20poly1305_decrypt) X(ccchacha20poly1305_finalize) X(ccchacha20poly1305_verify) X(ccchacha20poly1305_encrypt_oneshot) X(ccchacha20poly1305_decrypt_oneshot)
#define ALL(X) CHACHA(X) POLY(X) AEAD(X)
#define FIELD(n) __typeof__(&n) n;
struct api{ALL(FIELD)};
int main(int argc,char**argv)
{
    if(argc!=2)return 2;void*h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL|RTLD_FIRST)};if(!h[0]||!h[1])return 2;
    struct api f[2];for(int i=0;i<2;i++){
#define LOAD(n) f[i].n=sym(h[i],#n);
        ALL(LOAD)
    }
    unsigned char key[32],nonce[12],input[4096],out[2][4128],tag[2][32];for(size_t i=0;i<sizeof(input);i++)input[i]=(unsigned char)(i*37+7);memcpy(key,input,32);memcpy(nonce,input+43,12);
    size_t lengths[]={0,1,7,15,16,17,31,32,63,64,65,127,128,129,511,1024,2048};
    for(int init=0;init<2;init++)for(int update=0;update<2;update++)for(int final=0;final<2;final++)for(size_t l=0;l<17;l++)for(size_t cut=0;cut<=lengths[l];cut+=lengths[l]/7+1){
        size_t n=lengths[l];struct ccchacha20_ctx c[2];struct ccpoly1305_ctx p[2];memset(c,0xa5,sizeof(c));memset(p,0xa5,sizeof(p));memset(out,0xa5,sizeof(out));memset(tag,0xa5,sizeof(tag));
        for(int i=0;i<2;i++){struct api*a=f+(i?init:0);num("chacha init",a->ccchacha20_init(c+i,key),0);a->ccchacha20_setnonce(c+i,nonce);a->ccchacha20_setcounter(c+i,l%2?UINT32_MAX:17);a->ccpoly1305_init(p+i,key);}
        same("chacha init context",c,c+1,sizeof(c[0]));same("poly init context",p,p+1,sizeof(p[0]));
        for(int i=0;i<2;i++){struct api*a=f+(i?update:0);a->ccchacha20_update(c+i,cut,input,out[i]+8);a->ccpoly1305_update(p+i,cut,input);}
        same("chacha split context",c,c+1,sizeof(c[0]));same("chacha split output",out,out+1,sizeof(out[0]));same("poly split context",p,p+1,sizeof(p[0]));
        for(int i=0;i<2;i++){struct api*a=f+(i?final:0);a->ccchacha20_update(c+i,n-cut,input+cut,out[i]+8+cut);a->ccpoly1305_update(p+i,n-cut,input+cut);}
        same("chacha continued context",c,c+1,sizeof(c[0]));same("chacha output",out,out+1,sizeof(out[0]));same("poly continued context",p,p+1,sizeof(p[0]));
        for(int i=0;i<2;i++){struct api*a=f+(i?final:0);a->ccpoly1305_final(p+i,tag[i]+8);a->ccchacha20_final(c+i);}
        same("poly final tag",tag,tag+1,sizeof(tag[0]));same("poly final context",p,p+1,sizeof(p[0]));same("chacha final wipe",c,c+1,sizeof(c[0]));
    }
    for(size_t l=0;l<17;l++)for(size_t al=0;al<12;al++)for(int init=0;init<2;init++)for(int update=0;update<2;update++)for(int final=0;final<2;final++){
        size_t n=lengths[l],aad=lengths[al];struct ccchacha20poly1305_ctx c[2];memset(c,0xa5,sizeof(c));memset(out,0xa5,sizeof(out));memset(tag,0xa5,sizeof(tag));int result[2];
        for(int i=0;i<2;i++){struct api*a=f+(i?init:0);a->ccchacha20poly1305_init(a->ccchacha20poly1305_info(),c+i,key);a->ccchacha20poly1305_setnonce(a->ccchacha20poly1305_info(),c+i,nonce);}
        same("aead init context",c,c+1,sizeof(c[0]));
        for(int i=0;i<2;i++){struct api*a=f+(i?update:0);a->ccchacha20poly1305_aad(NULL,c+i,aad/2,input);a->ccchacha20poly1305_aad(NULL,c+i,aad-aad/2,input+aad/2);a->ccchacha20poly1305_encrypt(NULL,c+i,n/3,input,out[i]+8);}
        same("aead split context",c,c+1,sizeof(c[0]));same("aead split output",out,out+1,sizeof(out[0]));
        for(int i=0;i<2;i++){struct api*a=f+(i?final:0);a->ccchacha20poly1305_encrypt(NULL,c+i,n-n/3,input+n/3,out[i]+8+n/3);result[i]=a->ccchacha20poly1305_finalize(NULL,c+i,tag[i]+8);}
        num("aead final result",result[0],result[1]);same("aead final context",c,c+1,sizeof(c[0]));same("aead ciphertext",out,out+1,sizeof(out[0]));same("aead tag",tag,tag+1,sizeof(tag[0]));
        unsigned char plain[2][4128];memset(plain,0xa5,sizeof(plain));
        for(int i=0;i<2;i++)result[i]=f[i].ccchacha20poly1305_decrypt_oneshot(NULL,key,nonce,aad,input,n,out[0]+8,plain[i]+8,tag[0]+8);
        num("aead decrypt result",result[0],result[1]);same("aead plaintext",plain,plain+1,sizeof(plain[0]));same("aead roundtrip",plain[1]+8,input,n);
        tag[0][8]^=1;for(int i=0;i<2;i++)result[i]=f[i].ccchacha20poly1305_decrypt_oneshot(NULL,key,nonce,aad,input,n,out[0]+8,plain[i]+8,tag[0]+8);num("aead wrong tag result",result[0],result[1]);num("aead wrong tag rejected",result[1],-1);
    }
    printf("ChaCha/Poly1305 ABI: %u checks, %u failures\n",checks,failures);return failures?1:0;
}
