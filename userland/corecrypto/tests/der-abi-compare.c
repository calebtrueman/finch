/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccder.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks,failures;
static void same(const char*n,const void*a,const void*b,size_t z){checks++;if(memcmp(a,b,z)&&failures++<15)fprintf(stderr,"%s differs\n",n);}
static void result(const char*n,int a,int b){same(n,&a,&b,sizeof(a));}
static void *sym(void*h,const char*n){void*p=dlsym(h,n);if(!p){fprintf(stderr,"%s\n",dlerror());exit(2);}return p;}
static ptrdiff_t offset(const unsigned char*p,const unsigned char*base){return p?p-base:-1;}
#define COMMON(X) X(sizeof_tag) X(sizeof_len) X(sizeof) X(sizeof_overflow) X(blob_encode_tag) X(blob_encode_len) X(blob_encode_tl) X(blob_reserve) X(blob_reserve_tl) X(blob_encode_body) X(blob_encode_body_tl) X(blob_decode_tag) X(encode_tag) X(encode_len) X(encode_tl) X(encode_body) X(encode_body_nocopy) X(encode_constructed_tl) X(decode_tag)
#define DECODERS(X,s) X(blob_decode_len##s) X(blob_decode_tl##s) X(blob_decode_range##s) X(blob_decode_sequence_tl##s) X(decode_len##s) X(decode_tl##s) X(decode_constructed_tl##s) X(decode_sequence_tl##s)
#define ALL(X) COMMON(X) DECODERS(X,) DECODERS(X,_strict)
#define FIELD(n) __typeof__(&ccder_##n) fn_##n;
struct api{ALL(FIELD)};
#undef FIELD
static void decode_cases(struct api f[2],const unsigned char *input,size_t size,ccder_tag expected)
{
    struct ccder_read_blob blob[2],range[2];bool ok[2];size_t value[2];const unsigned char*p[2],*ends[2];
    ccder_tag tag[2]={0x5555555555555555,0x5555555555555555};
    for(int i=0;i<2;i++){blob[i]=(struct ccder_read_blob){input,input?input+size:NULL};ok[i]=f[i].fn_blob_decode_tag(&blob[i],tag+i);}
    result("blob tag result",ok[0],ok[1]);same("blob tag value",tag,tag+1,sizeof(tag[0]));same("blob tag progress",blob,blob+1,sizeof(blob[0]));
    tag[0]=tag[1]=0x5555555555555555;
    for(int i=0;i<2;i++)p[i]=f[i].fn_decode_tag(tag+i,input,input?input+size:NULL);
    same("tag wrapper pointer",p,p+1,sizeof(p[0]));same("tag wrapper value",tag,tag+1,sizeof(tag[0]));
    for(int strict=0;strict<2;strict++){
        for(int i=0;i<2;i++){
            blob[i]=(struct ccder_read_blob){input,input?input+size:NULL};value[i]=999;
            ok[i]=(strict?f[i].fn_blob_decode_len_strict:f[i].fn_blob_decode_len)(&blob[i],value+i);
        }
        result("blob length result",ok[0],ok[1]);same("blob length value",value,value+1,sizeof(value[0]));same("blob length progress",blob,blob+1,sizeof(blob[0]));
        for(int i=0;i<2;i++){value[i]=999;p[i]=(strict?f[i].fn_decode_len_strict:f[i].fn_decode_len)(value+i,input,input?input+size:NULL);}
        same("length wrapper value",value,value+1,sizeof(value[0]));same("length wrapper pointer",p,p+1,sizeof(p[0]));
        for(int i=0;i<2;i++){
            blob[i]=(struct ccder_read_blob){input,input?input+size:NULL};value[i]=999;
            ok[i]=(strict?f[i].fn_blob_decode_tl_strict:f[i].fn_blob_decode_tl)(&blob[i],expected,value+i);
        }
        result("blob TL result",ok[0],ok[1]);same("blob TL length",value,value+1,sizeof(value[0]));same("blob TL progress",blob,blob+1,sizeof(blob[0]));
        for(int i=0;i<2;i++){value[i]=999;p[i]=(strict?f[i].fn_decode_tl_strict:f[i].fn_decode_tl)(expected,value+i,input,input?input+size:NULL);}
        same("TL wrapper value",value,value+1,sizeof(value[0]));same("TL wrapper pointer",p,p+1,sizeof(p[0]));
        for(int i=0;i<2;i++){
            blob[i]=(struct ccder_read_blob){input,input?input+size:NULL};memset(range+i,0xa5,sizeof(range[0]));
            ok[i]=(strict?f[i].fn_blob_decode_range_strict:f[i].fn_blob_decode_range)(&blob[i],expected,range+i);
        }
        result("range result",ok[0],ok[1]);same("range bytes",range,range+1,sizeof(range[0]));same("range progress",blob,blob+1,sizeof(blob[0]));
        for(int i=0;i<2;i++)p[i]=(strict?f[i].fn_decode_constructed_tl_strict:f[i].fn_decode_constructed_tl)(expected,ends+i,input,input?input+size:NULL);
        same("constructed pointer",p,p+1,sizeof(p[0]));same("constructed end",ends,ends+1,sizeof(ends[0]));
        for(int i=0;i<2;i++){
            blob[i]=(struct ccder_read_blob){input,input?input+size:NULL};memset(range+i,0xa5,sizeof(range[0]));
            ok[i]=(strict?f[i].fn_blob_decode_sequence_tl_strict:f[i].fn_blob_decode_sequence_tl)(&blob[i],range+i);
        }
        result("sequence range result",ok[0],ok[1]);same("sequence range",range,range+1,sizeof(range[0]));same("sequence progress",blob,blob+1,sizeof(blob[0]));
        for(int i=0;i<2;i++)p[i]=(strict?f[i].fn_decode_sequence_tl_strict:f[i].fn_decode_sequence_tl)(ends+i,input,input?input+size:NULL);
        same("sequence pointer",p,p+1,sizeof(p[0]));same("sequence end",ends,ends+1,sizeof(ends[0]));
    }
}
int main(int argc,char**argv)
{
    if(argc!=2)return 2;
    void*h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL|RTLD_FIRST)};if(!h[0]||!h[1])return 2;
    struct api f[2];for(int i=0;i<2;i++){
#define LOAD_EXPANDED(n) f[i].fn_##n=sym(h[i],"ccder_"#n);
#define LOAD(n) LOAD_EXPANDED(n)
        ALL(LOAD)
#undef LOAD
#undef LOAD_EXPANDED
    }
    if(f[0].fn_encode_tag==f[1].fn_encode_tag)return 2;
    const ccder_tag tags[]={0,2,16,30,31,127,128,16383,16384,2097151,2097152,268435455,268435456,UINT32_MAX,UINT64_C(0x1fffffffffffffff)};
    const size_t sizes[]={0,1,127,128,255,256,65535,65536,16777215,16777216,UINT32_MAX,UINT64_C(1)<<32,UINT64_C(1)<<56,SIZE_MAX-10,SIZE_MAX};
    for(size_t t=0;t<sizeof(tags)/sizeof(*tags);t++)for(unsigned cls=0;cls<8;cls++){
        ccder_tag tag=tags[t]|((uint64_t)cls<<61);size_t z[2];for(int i=0;i<2;i++)z[i]=f[i].fn_sizeof_tag(tag);same("tag size",z,z+1,sizeof(size_t));
        for(size_t l=0;l<sizeof(sizes)/sizeof(*sizes);l++){
            for(int i=0;i<2;i++)z[i]=f[i].fn_sizeof_len(sizes[l]);same("length size",z,z+1,sizeof(size_t));
            for(int i=0;i<2;i++)z[i]=f[i].fn_sizeof(tag,sizes[l]);same("total size",z,z+1,sizeof(size_t));
            for(int overflow=0;overflow<2;overflow++){bool ov[2]={overflow,overflow};for(int i=0;i<2;i++)z[i]=f[i].fn_sizeof_overflow(tag,sizes[l],ov+i);same("size overflow result",z,z+1,sizeof(size_t));same("size overflow flag",ov,ov+1,sizeof(bool));}
            for(size_t capacity=0;capacity<=12;capacity++)for(int operation=0;operation<6;operation++){
                unsigned char bytes[2][40];memset(bytes,0xa5,sizeof(bytes));struct ccder_blob b[2];ptrdiff_t where[2];bool ok[2]={0};
                for(int i=0;i<2;i++){
                    b[i]=(struct ccder_blob){bytes[i]+8,bytes[i]+8+capacity};unsigned char*p=NULL;
                    switch(operation){
                    case 0:ok[i]=f[i].fn_blob_encode_tag(b+i,tag);break;
                    case 1:ok[i]=f[i].fn_blob_encode_len(b+i,sizes[l]);break;
                    case 2:ok[i]=f[i].fn_blob_encode_tl(b+i,tag,sizes[l]);break;
                    case 3:p=f[i].fn_encode_tag(tag,b[i].start,b[i].end);break;
                    case 4:p=f[i].fn_encode_len(sizes[l],b[i].start,b[i].end);break;
                    case 5:p=f[i].fn_encode_tl(tag,sizes[l],b[i].start,b[i].end);break;
                    }
                    where[i]=offset(operation<3?b[i].end:p,bytes[i]);
                }
                result("encode result",ok[0],ok[1]);same("encode progress",where,where+1,sizeof(where[0]));same("encode bytes/guards",bytes[0],bytes[1],40);
            }
        }
    }
    unsigned char source[64];for(size_t i=0;i<64;i++)source[i]=i*7+1;
    for(size_t capacity=0;capacity<=32;capacity++)for(size_t length=0;length<=34;length++)for(int operation=0;operation<8;operation++){
        unsigned char bytes[2][96];memset(bytes,0xa5,sizeof(bytes));bool ok[2]={0};ptrdiff_t where[2][3];
        for(int i=0;i<2;i++){
            struct ccder_blob b={bytes[i]+8,bytes[i]+8+capacity},out={NULL,NULL};unsigned char*p=NULL;
            switch(operation){
            case 0:ok[i]=f[i].fn_blob_reserve(&b,length,&out);break;
            case 1:ok[i]=f[i].fn_blob_reserve_tl(&b,4,length,&out);break;
            case 2:ok[i]=f[i].fn_blob_encode_body(&b,length,source);break;
            case 3:ok[i]=f[i].fn_blob_encode_body(&b,length,NULL);break;
            case 4:ok[i]=f[i].fn_blob_encode_body_tl(&b,4,length,source);break;
            case 5:p=f[i].fn_encode_body(length,source,b.start,b.end);break;
            case 6:p=f[i].fn_encode_body_nocopy(length,b.start,b.end);break;
            case 7:p=f[i].fn_encode_constructed_tl(CCDER_SEQUENCE,b.end+length,b.start,b.end);break;
            }
            where[i][0]=offset(operation<5?b.end:p,bytes[i]);where[i][1]=offset(out.start,bytes[i]);where[i][2]=offset(out.end,bytes[i]);
        }
        result("body result",ok[0],ok[1]);same("body pointers",where[0],where[1],sizeof(where[0]));same("body bytes/guards",bytes[0],bytes[1],96);
    }
    decode_cases(f,NULL,0,2);
    unsigned char input[520];
    for(unsigned first=0;first<256;first++)for(unsigned second=0;second<256;second+=7){
        memset(input,0,sizeof(input));input[0]=first;input[1]=second;input[2]=0x81;input[3]=0x80;input[4]=0x01;
        decode_cases(f,input,(first+second)%12,(first&31)|((uint64_t)(first>>5)<<61));
    }
    for(size_t length=0;length<260;length++)for(unsigned form=0;form<6;form++){
        memset(input,0,sizeof(input));input[0]=0x30;
        if(!form)input[1]=(unsigned char)length;
        else{input[1]=128+form;for(unsigned j=0;j<form;j++)input[2+j]=(unsigned char)(length>>((form-1-j)*8));}
        size_t header=2+(form?form:0);
        decode_cases(f,input,header+length,CCDER_SEQUENCE);
        if(length)decode_cases(f,input,header+length-1,CCDER_SEQUENCE);
    }
    uint64_t seed=0x9e3779b97f4a7c15ULL;
    for(size_t trial=0;trial<10000;trial++){
        for(size_t i=0;i<32;i++){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;input[i]=(unsigned char)seed;}
        if(trial%3==0){input[0]=0x1f;for(size_t i=1;i<10;i++)input[i]|=128;input[10]&=127;}
        decode_cases(f,input,trial%33,trial%2?2:CCDER_SEQUENCE);
    }
    printf("DER headers ABI: %u checks, %u failures\n",checks,failures);return failures?1:0;
}
