/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccmode.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks,failures;
static void same(const char *n,const void*a,const void*b,size_t z){checks++;if(memcmp(a,b,z)&&failures++<12)fprintf(stderr,"%s differs\n",n);}
static void result(const char*n,int a,int b){same(n,&a,&b,sizeof(a));}
static void *sym(void*h,const char*n){void*p=dlsym(h,n);if(!p){fprintf(stderr,"%s\n",dlerror());exit(2);}return p;}
int main(int argc,char**argv){
    if(argc!=2)return 2;
    void*h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL|RTLD_FIRST)};
    if(!h[0]||!h[1])return 2;
    const struct ccmode_ctr *(*get[2])(void)={sym(h[0],"ccaes_ctr_crypt_mode"),sym(h[1],"ccaes_ctr_crypt_mode")};
    const struct ccmode_ctr*m[2]={get[0](),get[1]()};
    if(m[0]==m[1])return 2;
    same("descriptor sizes",m[0],m[1],24);
    const size_t lengths[]={0,15,16,17,24,32,128,192,256};
    const size_t sizes[]={0,1,15,16,17,31,32,127,256};
    unsigned char key[256],input[256],iv[16];
    for(size_t i=0;i<256;i++){key[i]=(unsigned char)i;input[i]=(unsigned char)(i*61);}
    for(int carry=0;carry<2;carry++){
        memset(iv,carry?0xff:0x31,sizeof(iv));
        for(size_t k=0;k<sizeof(lengths)/sizeof(*lengths);k++){
            _Alignas(16) unsigned char base[2][320];int r[2];memset(base,0xa5,sizeof(base));
            for(int i=0;i<2;i++)r[i]=m[i]->init(m[i],base[i],lengths[k],key,iv);
            result("init",r[0],r[1]);same("init bytes",base[0]+8,base[1]+8,312);
            if(r[0])continue;
            for(size_t n=0;n<sizeof(sizes)/sizeof(*sizes);n++)for(int split=0;split<2;split++){
                unsigned char reference[272],refctx[320];memset(reference,0x5a,sizeof(reference));memcpy(refctx,base[0],320);
                size_t reference_first=split?sizes[n]/2:0;
                result("reference first",0,m[0]->ctr(refctx,reference_first,input,reference));
                result("reference rest",0,m[0]->ctr(refctx,sizes[n]-reference_first,input+reference_first,reference+reference_first));
                for(int caller=0;caller<2;caller++)for(int context=0;context<2;context++)for(int inplace=0;inplace<2;inplace++){
                    _Alignas(16) unsigned char ctx[320];unsigned char out[272];memcpy(ctx,base[context],320);memset(out,0x5a,sizeof(out));if(inplace)memcpy(out,input,256);
                    size_t first=split?sizes[n]/2:0;
                    result("first",0,m[caller]->ctr(ctx,first,inplace?out:input,out));
                    result("rest",0,m[caller]->ctr(ctx,sizes[n]-first,(inplace?out:input)+first,out+first));
                    same("output",reference,out,sizes[n]);
                    same("saved state",refctx+8,ctx+8,40);
                    same("key and guard",base[context]+48,ctx+48,272);
                    /* Resume with the other implementation after any split. */
                    unsigned char tail[16],expected[16],copy[320];memcpy(copy,refctx,320);
                    m[0]->ctr(copy,16,input,expected);m[1-caller]->ctr(ctx,16,input,tail);
                    same("continued output",expected,tail,16);
                }
            }
        }
    }
    printf("CTR ABI: %u checks, %u failures\n",checks,failures);return failures?1:0;
}
