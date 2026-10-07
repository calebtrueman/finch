/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccdigest.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks, failures;
static void same(const char *name, const void *a, const void *b, size_t n)
{ checks++; if (memcmp(a,b,n) && failures++ < 12) fprintf(stderr,"%s differs\n",name); }
static void result(const char *name, int a, int b) { same(name,&a,&b,sizeof(a)); }
static void *sym(void *h,const char *name)
{ void *p=dlsym(h,name);if(!p){fprintf(stderr,"%s\n",dlerror());exit(2);}return p; }
typedef const struct ccdigest_info *(*digest_fn)(void);
typedef int (*extract_fn)(const struct ccdigest_info*,size_t,const void*,size_t,const void*,void*);
typedef int (*expand_fn)(const struct ccdigest_info*,size_t,const void*,size_t,const void*,size_t,void*);
typedef int (*hkdf_fn)(const struct ccdigest_info*,size_t,const void*,size_t,const void*,size_t,const void*,size_t,void*);
typedef int (*pbkdf_fn)(const struct ccdigest_info*,size_t,const void*,size_t,const void*,uint64_t,size_t,void*);
int main(int argc,char **argv)
{
    if(argc!=2)return 2;
    void *h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL|RTLD_FIRST)};
    if(!h[0]||!h[1])return 2;
    extract_fn extract[2];expand_fn expand[2],x963[2];hkdf_fn hkdf[2],nist[2];expand_fn nist_fixed[2];pbkdf_fn pbkdf[2];
    for(int i=0;i<2;i++){
        nist[i]=sym(h[i],"ccnistkdf_ctr_hmac");nist_fixed[i]=sym(h[i],"ccnistkdf_ctr_hmac_fixed");
        extract[i]=sym(h[i],"cchkdf_extract");expand[i]=sym(h[i],"cchkdf_expand");
        hkdf[i]=sym(h[i],"cchkdf");pbkdf[i]=sym(h[i],"ccpbkdf2_hmac");x963[i]=sym(h[i],"ccansikdf_x963");
    }
    if(hkdf[0]==hkdf[1])return 2;
    unsigned char input[200],salt[200],info[200];
    for(size_t i=0;i<200;i++){input[i]=i*13;salt[i]=i*17+3;info[i]=i*7+1;}
    const char *names[]={"ccsha1_di","ccsha224_di","ccsha256_di","ccsha384_di","ccsha512_di"};
    const size_t lengths[]={0,1,15,31,32,63,64,65,127,128,129,199};
    for(size_t d=0;d<5;d++)for(int provider=0;provider<2;provider++){
        digest_fn get=sym(h[provider],names[d]);const struct ccdigest_info *di=get();
        for(size_t a=0;a<sizeof(lengths)/sizeof(*lengths);a++)for(size_t b=0;b<sizeof(lengths)/sizeof(*lengths);b++){
            size_t n=lengths[a],s=lengths[b],z=lengths[(a+b)%12];
            unsigned char out[2][256];int r[2];memset(out,0xa5,sizeof(out));
            for(int i=0;i<2;i++)r[i]=extract[i](di,s,s?salt:NULL,n,n?input:NULL,out[i]+8);
            result("extract result",r[0],r[1]);same("extract bytes/guards",out[0],out[1],256);
            memset(out,0xa5,sizeof(out));
            for(int i=0;i<2;i++)r[i]=hkdf[i](di,n,n?input:NULL,s,s?salt:NULL,z,z?info:NULL,199,out[i]+8);
            result("HKDF result",r[0],r[1]);same("HKDF bytes/guards",out[0],out[1],256);
            memset(out,0xa5,sizeof(out));
            for(int i=0;i<2;i++)r[i]=expand[i](di,n,n?input:NULL,s,s?info:NULL,z,out[i]+8);
            result("expand result",r[0],r[1]);same("expand bytes/guards",out[0],out[1],256);
            for(uint64_t rounds=0;rounds<5;rounds++){
                memset(out,0xa5,sizeof(out));
                for(int i=0;i<2;i++)r[i]=pbkdf[i](di,n,n?input:NULL,s,s?salt:NULL,rounds,z,out[i]+8);
                result("PBKDF result",r[0],r[1]);same("PBKDF bytes/guards",out[0],out[1],256);
            }
            memset(out,0xa5,sizeof(out));
            for(int i=0;i<2;i++)r[i]=nist_fixed[i](di,n,n?input:NULL,s,s?info:NULL,z,out[i]+8);
            result("NIST fixed result",r[0],r[1]);same("NIST fixed bytes/guards",out[0],out[1],256);
            memset(out,0xa5,sizeof(out));
            for(int i=0;i<2;i++)r[i]=nist[i](di,n,n?input:NULL,s,s?salt:NULL,z,z?info:NULL,199,out[i]+8);
            result("NIST result",r[0],r[1]);same("NIST bytes/guards",out[0],out[1],256);
            /* Host X9.63 writes beyond a zero-byte request; test only positive sizes. */
            memset(out,0xa5,sizeof(out));
            for(int i=0;i<2;i++)r[i]=x963[i](di,n,n?input:NULL,s,s?info:NULL,z?z:1,out[i]+8);
            result("X963 result",r[0],r[1]);same("X963 bytes/guards",out[0],out[1],256);
        }
        size_t max=di->output_size*255;
        for(int delta=-1;delta<=1;delta++){
            unsigned char out[2][16400];memset(out,0xa5,sizeof(out));int r[2];
            for(int i=0;i<2;i++)r[i]=expand[i](di,199,input,199,info,max+delta,out[i]+8);
            result("HKDF limit result",r[0],r[1]);same("HKDF limit bytes/guards",out[0],out[1],sizeof(out[0]));
        }
        unsigned char out[2][32];memset(out,0xa5,sizeof(out));int r[2];
        for(int i=0;i<2;i++)r[i]=pbkdf[i](di,0,NULL,0,NULL,1,di->output_size*((uint64_t)UINT32_MAX+1),out[i]);
        result("PBKDF limit",r[0],r[1]);same("PBKDF limit guard",out[0],out[1],32);
        for(int i=0;i<2;i++)r[i]=x963[i](di,0,NULL,0,NULL,di->output_size*(uint64_t)UINT32_MAX,out[i]);
        result("X963 limit",r[0],r[1]);same("X963 limit guard",out[0],out[1],32);
        for(int i=0;i<2;i++)r[i]=nist_fixed[i](di,199,input,0,NULL,di->output_size*((uint64_t)UINT32_MAX+1),out[i]);
        result("NIST fixed limit",r[0],r[1]);same("NIST fixed limit guard",out[0],out[1],32);
        for(int i=0;i<2;i++)r[i]=nist[i](di,199,input,0,NULL,0,NULL,UINT32_MAX/8+1ULL,out[i]);
        result("NIST limit",r[0],r[1]);same("NIST limit guard",out[0],out[1],32);
        for(int i=0;i<2;i++)r[i]=nist_fixed[i](di,199,input,0,NULL,1,NULL);
        result("NIST NULL output",r[0],r[1]);
        result("Finch HKDF huge size",-7,expand[1](di,199,input,0,NULL,SIZE_MAX,out[1]));
        result("Finch X963 zero size",0,x963[1](di,0,NULL,0,NULL,0,out[1]));
        same("Finch X963 zero guard",out[0],out[1],32);
    }
    /* RFC 5869 test case 1, independently fixed expected bytes. */
    digest_fn get=sym(h[1],"ccsha256_di");unsigned char ikm[22],s[13],in[10],out[42];
    memset(ikm,0x0b,sizeof(ikm));for(int i=0;i<13;i++)s[i]=i;for(int i=0;i<10;i++)in[i]=0xf0+i;
    const unsigned char expected[]={0x3c,0xb2,0x5f,0x25,0xfa,0xac,0xd5,0x7a,0x90,0x43,0x4f,0x64,0xd0,0x36,0x2f,0x2a,0x2d,0x2d,0x0a,0x90,0xcf,0x1a,0x5a,0x4c,0x5d,0xb0,0x2d,0x56,0xec,0xc4,0xc5,0xbf,0x34,0x00,0x72,0x08,0xd5,0xb8,0x87,0x18,0x58,0x65};
    result("HKDF vector result",0,hkdf[1](get(),22,ikm,13,s,10,in,42,out));same("HKDF vector",out,expected,42);
    printf("KDF ABI: %u checks, %u failures\n",checks,failures);return failures?1:0;
}
