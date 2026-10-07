/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccmode.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks,failures;static const char *current;static size_t keysize,length;
static void same(const char*n,const void*a,const void*b,size_t z){checks++;if(memcmp(a,b,z)&&failures++<12){fprintf(stderr,"%s: %s differs, key%zu length%zu\n",current,n,keysize,length);for(size_t i=0;i<z;i++)if(((const unsigned char*)a)[i]!=((const unsigned char*)b)[i]){fprintf(stderr,"byte%zu: %02x/%02x\n",i,((const unsigned char*)a)[i],((const unsigned char*)b)[i]);break;}}}
static void result(const char*n,int a,int b){same(n,&a,&b,sizeof(a));}
static void *sym(void*h,const char*n){void*p=dlsym(h,n);if(!p){fprintf(stderr,"%s\n",dlerror());exit(2);}return p;}
int main(int argc,char**argv)
{
    if(argc!=2)return 2;
    void*h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL|RTLD_FIRST)};
    if(!h[0]||!h[1])return 2;
    const char *names[]={"ccaes_cfb_encrypt_mode","ccaes_cfb_decrypt_mode","ccaes_cfb8_encrypt_mode","ccaes_cfb8_decrypt_mode","ccaes_ofb_crypt_mode"};
    const char *factories[]={"ccmode_factory_cfb_encrypt","ccmode_factory_cfb_decrypt","ccmode_factory_cfb8_encrypt","ccmode_factory_cfb8_decrypt","ccmode_factory_ofb_crypt"};
    const char *once_names[]={"cccfb_one_shot","cccfb_one_shot","cccfb8_one_shot","cccfb8_one_shot","ccofb_one_shot"};
    const size_t keys[]={0,15,16,17,24,32,128,192,256},sizes[]={0,1,15,16,17,31,32,127,256};
    unsigned char key[256],iv[16],input[256];for(size_t i=0;i<256;i++){key[i]=(unsigned char)(i*17+3);input[i]=(unsigned char)(i*31+7);}for(size_t i=0;i<16;i++)iv[i]=(unsigned char)(i*11+9);
    typedef int(*once_fn)(const struct ccmode_stream*,size_t,const void*,const void*,size_t,const void*,void*);
    for(int mode=0;mode<5;mode++)for(int generic=0;generic<2;generic++){
        current=names[mode];
        const struct ccmode_stream*(*get[2])(void)={sym(h[0],current),sym(h[1],current)};
        const struct ccmode_stream*m[2]={get[0](),get[1]()};struct ccmode_stream generated[2];
        if(m[0]==m[1])return 2;
        if(generic)for(int i=0;i<2;i++){void(*factory)(struct ccmode_stream*,const struct ccmode_ecb*)=sym(h[i],factories[mode]);factory(generated+i,m[i]->custom);m[i]=generated+i;}
        once_fn once[2]={sym(h[0],once_names[mode]),sym(h[1],once_names[mode])};same("sizes",m[0],m[1],16);
        for(size_t k=0;k<9;k++)for(int nulliv=0;nulliv<(mode==4?1:2);nulliv++){
            keysize=keys[k];
            /* Host CFB8 calls AES even after failed key setup. Its uninitialized
             * round count can crash, so compare this mode only with valid keys. */
            if((mode==2||mode==3)&&(keysize!=16&&keysize!=24&&keysize!=32&&keysize!=128&&keysize!=192&&keysize!=256))continue;
_Alignas(16) unsigned char base[2][800];memset(base,0xa5,sizeof(base));int r[2];
            const void*nonce=nulliv?NULL:iv;
            for(int i=0;i<2;i++)r[i]=m[i]->init(m[i],base[i],keysize,key,nonce);
            result("init",r[0],r[1]);same("init state",base[0]+8,base[1]+8,792);
            for(size_t n=0;n<9;n++){
                length=sizes[n];unsigned char reference[272],out[272];memset(reference,0x5a,sizeof(reference));
                int expected=once[0](m[0],keysize,key,nonce,length,input,reference);
                for(int caller=0;caller<2;caller++)for(int desc=0;desc<2;desc++){
                    memset(out,0x5a,sizeof(out));result("one shot",expected,once[caller](m[desc],keysize,key,nonce,length,input,out));same("one shot bytes",reference,out,272);
                }
                if(r[0])continue;
                for(int split=0;split<2;split++){
                    _Alignas(16) unsigned char reference_ctx[800];memcpy(reference_ctx,base[0],800);
                    size_t first=split?length/2:0;
                    m[0]->crypt(reference_ctx,first,input,out);m[0]->crypt(reference_ctx,length-first,input+first,out+first);
                    for(int caller=0;caller<2;caller++)for(int context=0;context<2;context++)for(int inplace=0;inplace<2;inplace++){
                        _Alignas(16) unsigned char ctx[800];memcpy(ctx,base[context],800);memset(out,0x5a,sizeof(out));if(inplace)memcpy(out,input,256);
                        result("first",0,m[caller]->crypt(ctx,first,inplace?out:input,out));
                        result("rest",0,m[caller]->crypt(ctx,length-first,(inplace?out:input)+first,out+first));
                        same("split output",reference,out,length);same("saved state",reference_ctx+8,ctx+8,792);
                        unsigned char expected_tail[16],tail[16];_Alignas(16) unsigned char copy[800];memcpy(copy,reference_ctx,800);
                        m[0]->crypt(copy,16,input,expected_tail);m[1-caller]->crypt(ctx,16,input,tail);same("continued stream",expected_tail,tail,16);
                    }
                }
            }
        }
    }
    printf("Feedback ABI: %u checks, %u failures\n",checks,failures);return failures?1:0;
}
