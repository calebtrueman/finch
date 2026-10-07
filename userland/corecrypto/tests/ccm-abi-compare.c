/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccmode.h"
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks,failures;static size_t keysize,ivsize,aadsize,textsize,tagsize;
static void same(const char*n,const void*a,const void*b,size_t z){checks++;if(memcmp(a,b,z)&&failures++<12){fprintf(stderr,"%s differs key%zu iv%zu aad%zu text%zu tag%zu\n",n,keysize,ivsize,aadsize,textsize,tagsize);for(size_t i=0;i<z;i++)if(((const unsigned char*)a)[i]!=((const unsigned char*)b)[i]){fprintf(stderr,"byte%zu: %02x/%02x\n",i,((const unsigned char*)a)[i],((const unsigned char*)b)[i]);break;}}}
static void result(const char*n,int a,int b){same(n,&a,&b,sizeof(a));}
static void *sym(void*h,const char*n){void*p=dlsym(h,n);if(!p){fprintf(stderr,"%s\n",dlerror());exit(2);}return p;}
int main(int argc,char**argv)
{
    if(argc!=2)return 2;
    void*h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL|RTLD_FIRST)};
    if(!h[0]||!h[1])return 2;
    unsigned char key[32],iv[16],auth[64],input[256];for(size_t i=0;i<32;i++)key[i]=(unsigned char)(i*17+3);for(size_t i=0;i<16;i++)iv[i]=(unsigned char)(i*31+7);for(size_t i=0;i<64;i++)auth[i]=(unsigned char)(i*13+9);for(size_t i=0;i<256;i++)input[i]=(unsigned char)(i*67+23);
    const size_t keys[]={16,24,32},ivs[]={7,12,13},aads[]={0,1,14,15,16,33},texts[]={0,1,15,16,17,31,32,256},tags[]={4,8,16};
    const struct ccmode_ccm*mode[2][2];
    for(int direction=0;direction<2;direction++){
        const char*name=direction?"ccaes_ccm_decrypt_mode":"ccaes_ccm_encrypt_mode";
        const struct ccmode_ccm*(*get[2])(void)={sym(h[0],name),sym(h[1],name)};
        const struct ccmode_ccm*m[2]={get[0](),get[1]()};if(m[0]==m[1])return 2;
        mode[0][direction]=m[0];mode[1][direction]=m[1];same("descriptor sizes",m[0],m[1],24);same("direction bytes",&m[0]->encdec,&m[1]->encdec,8);
        for(size_t k=0;k<3;k++)for(size_t v=0;v<3;v++)for(size_t a=0;a<6;a++)for(size_t t=0;t<8;t++)for(size_t g=0;g<3;g++){
            keysize=keys[k];ivsize=ivs[v];aadsize=aads[a];textsize=texts[t];tagsize=tags[g];
            _Alignas(16) unsigned char ctx[5][320],nonce[5][128];unsigned char out[5][272],tag[5][32];
            memset(ctx,0xa5,sizeof(ctx));memset(nonce,0xa5,sizeof(nonce));memset(out,0x5a,sizeof(out));memset(tag,0x7b,sizeof(tag));
            for(int c=0;c<5;c++){
                int creator=c==0?0:(c-1)/2,caller=c==0?0:(c-1)%2;
                result("init",0,m[creator]->init(m[creator],ctx[c],keysize,key));
                result("set IV",0,m[caller]->set_iv(ctx[c],nonce[c],ivsize,iv,tagsize,aadsize,textsize));
            }
            for(int c=1;c<5;c++){same("key and guard",ctx[0]+8,ctx[c]+8,312);same("IV state",nonce[0],nonce[c],128);}
            for(int step=0;step<2;step++){
                size_t start=step?aadsize/2:0,n=step?aadsize-start:aadsize/2;
                for(int c=0;c<5;c++){int caller=c==0?0:(c-1)%2;result("aad",0,m[caller]->aad(ctx[c],nonce[c],n,auth+start));}
                for(int c=1;c<5;c++)same("aad state",nonce[0],nonce[c],128);
            }
            for(int step=0;step<2;step++){
                size_t start=step?textsize/2:0,n=step?textsize-start:textsize/2;
                for(int c=0;c<5;c++){int caller=c==0?0:(c-1)%2;result("crypt",0,m[caller]->ccm(ctx[c],nonce[c],n,input+start,out[c]+start));}
                for(int c=1;c<5;c++){same("crypt state",nonce[0],nonce[c],128);same("output",out[0],out[c],272);}
            }
            for(int c=0;c<5;c++){int caller=c==0?0:(c-1)%2;result("finalize",0,m[caller]->finalize(ctx[c],nonce[c],tag[c]));}
            for(int c=1;c<5;c++){same("final state",nonce[0],nonce[c],128);same("tag and guard",tag[0],tag[c],32);}
            for(int c=0;c<5;c++){int caller=c==0?0:(c-1)%2;result("reset",0,m[caller]->reset(ctx[c],nonce[c]));}
            for(int c=1;c<5;c++)same("reset state",nonce[0],nonce[c],128);
        }
    }
    /* RFC 3610, section 8, packet vector 1:
     * https://www.rfc-editor.org/rfc/rfc3610.html#section-8 */
    const unsigned char known_iv[13]={0,0,0,3,2,1,0,0xa0,0xa1,0xa2,0xa3,0xa4,0xa5};
    const unsigned char expected[31]={0x58,0x8c,0x97,0x9a,0x61,0xc6,0x63,0xd2,0xf0,0x66,0xd0,0xc2,0xc0,0xf9,0x89,0x80,0x6d,0x5f,0x6b,0x61,0xda,0xc3,0x84,0x17,0xe8,0xd1,0x2c,0xfd,0xf9,0x26,0xe0};
    unsigned char known_key[16],plain[31];for(size_t i=0;i<16;i++)known_key[i]=(unsigned char)(0xc0+i);for(size_t i=0;i<31;i++)plain[i]=(unsigned char)i;
    typedef int(*once_fn)(const struct ccmode_ccm*,size_t,const void*,size_t,const void*,size_t,const void*,void*,size_t,const void*,size_t,void*);
    once_fn once[2]={sym(h[0],"ccccm_one_shot"),sym(h[1],"ccccm_one_shot")};
    once_fn encrypt_once[2]={sym(h[0],"ccccm_one_shot_encrypt"),sym(h[1],"ccccm_one_shot_encrypt")};
    once_fn decrypt_once[2]={sym(h[0],"ccccm_one_shot_decrypt"),sym(h[1],"ccccm_one_shot_decrypt")};
    for(int caller=0;caller<2;caller++)for(int desc=0;desc<2;desc++)for(int inplace=0;inplace<2;inplace++){
        unsigned char cipher[39],tag[16],recovered[39];memset(cipher,0x5a,39);memset(tag,0x7b,16);memset(recovered,0x5a,39);if(inplace)memcpy(cipher,plain+8,23);
        result("known CCM",0,encrypt_once[caller](mode[desc][0],16,known_key,13,known_iv,23,inplace?cipher:plain+8,cipher,8,plain,8,tag));
        same("known ciphertext",expected,cipher,23);same("known tag",expected+23,tag,8);
        if(inplace)memcpy(recovered,cipher,23);
        result("valid tag",0,decrypt_once[caller](mode[desc][1],16,known_key,13,known_iv,23,inplace?recovered:cipher,recovered,8,plain,8,tag));
        same("known plaintext",plain+8,recovered,23);
        tag[0]^=1;result("altered tag",-69,decrypt_once[caller](mode[desc][1],16,known_key,13,known_iv,23,cipher,recovered,8,plain,8,tag));
        result("wrong direction",-68,encrypt_once[caller](mode[desc][1],16,known_key,13,known_iv,23,plain+8,cipher,8,plain,8,tag));
        result("legacy tag output",0,once[caller](mode[desc][0],16,known_key,13,known_iv,23,plain+8,cipher,8,plain,8,tag));same("legacy known tag",expected+23,tag,8);
    }
    for(ivsize=0;ivsize<=15;ivsize++)for(tagsize=0;tagsize<=18;tagsize++){
        _Alignas(16) unsigned char ctx[2][320],nonce[2][128];memset(ctx,0xa5,sizeof(ctx));memset(nonce,0xa5,sizeof(nonce));int r[2];
        for(int i=0;i<2;i++){mode[i][0]->init(mode[i][0],ctx[i],16,key);r[i]=mode[i][0]->set_iv(ctx[i],nonce[i],ivsize,iv,tagsize,17,33);}
        result("IV and tag sizes",r[0],r[1]);same("rejected state",nonce[0],nonce[1],128);
    }
    const size_t auth_sizes[]={0,0xfeff,0xff00,0xffff,UINT32_MAX,(size_t)UINT32_MAX+1};
    const size_t text_sizes[]={0,65535,65536,UINT32_MAX,SIZE_MAX};
    for(size_t a=0;a<6;a++)for(size_t t=0;t<5;t++){
        _Alignas(16) unsigned char ctx[2][320],nonce[2][128];memset(ctx,0xa5,sizeof(ctx));memset(nonce,0xa5,sizeof(nonce));int r[2];
        for(int i=0;i<2;i++){mode[i][0]->init(mode[i][0],ctx[i],16,key);r[i]=mode[i][0]->set_iv(ctx[i],nonce[i],13,iv,8,auth_sizes[a],text_sizes[t]);}
        result("size bounds",r[0],r[1]);same("size bound state",nonce[0],nonce[1],128);
    }
    for(int direction=0;direction<2;direction++)for(int provider=0;provider<2;provider++){
        struct ccmode_ccm m[2];
        for(int i=0;i<2;i++){
            void(*factory)(struct ccmode_ccm*,const struct ccmode_ecb*)=sym(h[i],direction?"ccmode_factory_ccm_decrypt":"ccmode_factory_ccm_encrypt");
            factory(m+i,mode[provider][direction]->custom);
        }
        same("factory sizes",m,m+1,24);same("factory tail",&m[0].custom,&m[1].custom,16);
        _Alignas(16) unsigned char ctx[2][320],nonce[2][128];unsigned char out[2][272],tag[2][32];
        memset(ctx,0xa5,sizeof(ctx));memset(nonce,0xa5,sizeof(nonce));memset(out,0x5a,sizeof(out));memset(tag,0x7b,sizeof(tag));
        for(int i=0;i<2;i++){
            result("factory init",0,m[i].init(m+i,ctx[i],24,key));
            result("factory IV",0,m[i].set_iv(ctx[i],nonce[i],12,iv,8,33,256));
            result("factory AAD",0,m[i].aad(ctx[i],nonce[i],33,auth));
            result("factory crypt",0,m[i].ccm(ctx[i],nonce[i],256,input,out[i]));
        }
        same("factory key",ctx[0],ctx[1],320);same("factory state",nonce[0],nonce[1],128);same("factory output",out[0],out[1],272);
        for(int i=0;i<2;i++)result("factory finalize",0,m[i].finalize(ctx[i],nonce[i],tag[i]));
        same("factory final state",nonce[0],nonce[1],128);same("factory tag",tag[0],tag[1],32);
    }
    printf("CCM ABI: %u checks, %u failures\n",checks,failures);return failures?1:0;
}
