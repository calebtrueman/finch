/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccder.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks,failures;
static void same(const char*n,const void*a,const void*b,size_t z){checks++;if(memcmp(a,b,z)&&failures++<20)fprintf(stderr,"%s differs\n",n);}
static void num(const char*n,ptrdiff_t a,ptrdiff_t b){same(n,&a,&b,sizeof(a));}
static ptrdiff_t off(const unsigned char*p,const unsigned char*base){return p?p-base:-1;}
static void *sym(void*h,const char*n){void*p=dlsym(h,n);if(!p){fprintf(stderr,"%s\n",dlerror());exit(2);}return p;}
#define ALL(X) X(decode_rsa_pub_n) X(decode_rsa_priv_n) X(decode_rsa_pub_x509_n) X(decode_dhparam_n) X(sizeof_eckey) X(encode_eckey_size) X(blob_encode_eckey) X(encode_eckey) X(blob_decode_eckey) X(decode_eckey) X(blob_decode_range) X(blob_decode_range_strict) X(blob_decode_bitstring)
#define FIELD(n) __typeof__(&ccder_##n) fn_##n;
struct api{ALL(FIELD)};
struct decoded{uint64_t version;size_t privsize,pubsize,bits;const unsigned char*priv,*oid,*pub;};
static void decode(struct api*f,const unsigned char*start,const unsigned char*end)
{
    struct decoded d[2];struct ccder_read_blob b[2];bool ok[2];const unsigned char*p[2];
    num("rsa public width",f[0].fn_decode_rsa_pub_n(start,end),f[1].fn_decode_rsa_pub_n(start,end));
    num("rsa private width",f[0].fn_decode_rsa_priv_n(start,end),f[1].fn_decode_rsa_priv_n(start,end));
    num("rsa x509 width",f[0].fn_decode_rsa_pub_x509_n(start,end),f[1].fn_decode_rsa_pub_x509_n(start,end));
    num("dh width",f[0].fn_decode_dhparam_n(start,end),f[1].fn_decode_dhparam_n(start,end));
    memset(d,0xa5,sizeof(d));
    for(int i=0;i<2;i++){b[i]=(struct ccder_read_blob){start,end};ok[i]=f[i].fn_blob_decode_eckey(b+i,&d[i].version,&d[i].privsize,&d[i].priv,&d[i].oid,&d[i].pubsize,&d[i].pub,&d[i].bits);}
    num("eckey decode result",ok[0],ok[1]);same("eckey decode fields",d,d+1,sizeof(d[0]));same("eckey decode progress",b,b+1,sizeof(b[0]));
    memset(d,0xa5,sizeof(d));
    for(int i=0;i<2;i++)p[i]=f[i].fn_decode_eckey(&d[i].version,&d[i].privsize,&d[i].priv,&d[i].oid,&d[i].bits,&d[i].pub,start,end);
    same("eckey wrapper result",p,p+1,sizeof(p[0]));same("eckey wrapper fields",d,d+1,sizeof(d[0]));
}
int main(int argc,char**argv)
{
    if(argc!=2)return 2;void*h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL|RTLD_FIRST)};if(!h[0]||!h[1])return 2;
    struct api f[2];for(int i=0;i<2;i++){
#define LOAD(n) f[i].fn_##n=sym(h[i],"ccder_"#n);
        ALL(LOAD)
    }
    unsigned char key[80],public[140],oid[]={6,3,0x2b,0x65,0x70},out[2][320];memset(key,0x95,sizeof(key));memset(public,0x35,sizeof(public));
    size_t privsizes[]={0,1,7,32,66},pubsizes[]={0,1,33,65,127,128};
    for(size_t a=0;a<5;a++)for(size_t c=0;c<6;c++)for(int hasoid=0;hasoid<2;hasoid++)for(int nullkey=0;nullkey<2;nullkey++)for(int nullpub=0;nullpub<2;nullpub++){
        size_t sizes[2],aliases[2];for(int i=0;i<2;i++){sizes[i]=f[i].fn_sizeof_eckey(privsizes[a],hasoid?oid:NULL,pubsizes[c]);aliases[i]=f[i].fn_encode_eckey_size(privsizes[a],hasoid?oid:NULL,pubsizes[c]);}
        same("eckey size",sizes,sizes+1,sizeof(sizes[0]));same("eckey size alias",aliases,aliases+1,sizeof(aliases[0]));same("eckey size aliases agree",sizes,aliases,sizeof(sizes));
        for(size_t cap=0;cap<=sizes[0]+1;cap++){
            struct ccder_blob b[2];bool ok[2];unsigned char*p[2];memset(out,0xa5,sizeof(out));
            for(int i=0;i<2;i++){b[i]=(struct ccder_blob){out[i]+8,out[i]+8+cap};ok[i]=f[i].fn_blob_encode_eckey(b+i,privsizes[a],nullkey?NULL:key,hasoid?oid:NULL,pubsizes[c],nullpub?NULL:public);}
            num("eckey encode result",ok[0],ok[1]);num("eckey encode progress",off(b[0].end,out[0]),off(b[1].end,out[1]));same("eckey encode data",out,out+1,sizeof(out[0]));
            if(ok[0]){decode(f,b[0].end,out[0]+8+cap);decode(f,b[0].end,out[0]+7+cap);}
            memset(out,0xa5,sizeof(out));for(int i=0;i<2;i++)p[i]=f[i].fn_encode_eckey(privsizes[a],nullkey?NULL:key,hasoid?oid:NULL,pubsizes[c],nullpub?NULL:public,out[i]+8,out[i]+8+cap);
            num("eckey encode wrapper",off(p[0],out[0]),off(p[1],out[1]));same("eckey wrapper data",out,out+1,sizeof(out[0]));
        }
    }
    /* Mutate each byte in a valid file, including optional fields and lengths. */
    unsigned char original[320],data[320];memset(original,0xa5,sizeof(original));unsigned char*encoded=f[0].fn_encode_eckey(32,key,oid,65,public,original,original+sizeof(original));size_t length=(size_t)(original+sizeof(original)-encoded);
    for(size_t j=0;j<length;j++)for(unsigned value=0;value<256;value++){
        memcpy(data,encoded,length);data[j]=(unsigned char)value;decode(f,data,data+length);
    }
    const unsigned char rsa_public[]={0x30,0x10,2,9,0,0xff,0xee,0xdd,0xcc,0xbb,0xaa,0x99,0x88,2,3,1,0,1};
    const unsigned char rsa_private[]={0x30,0x13,2,1,0,2,9,0,0xff,0xee,0xdd,0xcc,0xbb,0xaa,0x99,0x88,2,3,1,0,1};
    const unsigned char rsa_x509[]={0x30,0x1c,0x30,7,6,3,0x2a,0x86,0x48,5,0,3,0x11,0,0x30,0x0e,2,9,0,0xff,0xee,0xdd,0xcc,0xbb,0xaa,0x99,0x88,2,1,3};
    const unsigned char *rsa[]={rsa_public,rsa_private,rsa_x509};size_t rsa_size[]={sizeof(rsa_public),sizeof(rsa_private),sizeof(rsa_x509)};
    for(int kind=0;kind<3;kind++){
        decode(f,rsa[kind],rsa[kind]+rsa_size[kind]);
        for(size_t j=0;j<rsa_size[kind];j++)for(unsigned value=0;value<256;value++){
            memcpy(data,rsa[kind],rsa_size[kind]);data[j]=(unsigned char)value;decode(f,data,data+rsa_size[kind]);
        }
    }
    decode(f,NULL,NULL);
    for(size_t j=0;j<1000;j++){
        memset(data,0xa5,sizeof(data));data[0]=(j&1)?3:0x30;data[1]=(unsigned char)(j%150);data[2]=(unsigned char)j;
        for(int strict=0;strict<2;strict++){
            struct ccder_read_blob b[2];bool ok[2];for(int i=0;i<2;i++){b[i]=(struct ccder_read_blob){data,data+2+j%151};ok[i]=(strict?f[i].fn_blob_decode_range_strict:f[i].fn_blob_decode_range)(b+i,data[0]==3?3:CCDER_SEQUENCE,b+i);}
            num("aliased range result",ok[0],ok[1]);same("aliased range",b,b+1,sizeof(b[0]));
        }
        struct ccder_read_blob b[2];size_t bits[2]={999,999};bool ok[2];for(int i=0;i<2;i++){b[i]=(struct ccder_read_blob){data,data+2+j%151};ok[i]=f[i].fn_blob_decode_bitstring(b+i,b+i,bits+i);}
        num("aliased bitstring result",ok[0],ok[1]);same("aliased bitstring range",b,b+1,sizeof(b[0]));same("aliased bitstring bits",bits,bits+1,sizeof(bits[0]));
    }
    printf("DER EC keys: %u checks, %u failures\n",checks,failures);return failures?1:0;
}
