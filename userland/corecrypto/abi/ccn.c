/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Numbers are arrays of 64-bit words, least significant word first.
 * Arithmetic visits every requested word, including leading zero words.
 */
#include "ccn.h"
#include <stdio.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
EXPORT uint64_t ccn_add(size_t n,cc_unit *r,const cc_unit *a,const cc_unit *b)
{
    uint64_t carry=0;
    for(size_t i=0;i<n;i++){__uint128_t sum=(__uint128_t)a[i]+b[i]+carry;r[i]=(uint64_t)sum;carry=sum>>64;}
    return carry;
}
EXPORT uint64_t ccn_sub(size_t n,cc_unit *r,const cc_unit *a,const cc_unit *b)
{
    uint64_t borrow=0;
    for(size_t i=0;i<n;i++){__uint128_t sub=(__uint128_t)b[i]+borrow;uint64_t value=a[i];r[i]=value-(uint64_t)sub;borrow=(__uint128_t)value<sub;}
    return borrow;
}
EXPORT uint64_t ccn_add1(size_t n,cc_unit *r,const cc_unit *a,cc_unit carry)
{
    for(size_t i=0;i<n;i++){__uint128_t sum=(__uint128_t)a[i]+carry;r[i]=(uint64_t)sum;carry=sum>>64;}
    return carry;
}
EXPORT size_t ccn_bitlen(size_t n,const cc_unit *a)
{
    size_t bits=0;
    for(size_t i=0;i<n;i++){
        uint64_t mask=0-(uint64_t)(a[i]!=0);
        size_t current=i*64+64-(unsigned)__builtin_clzll(a[i]|1);
        bits=(bits&~mask)|(current&mask);
    }
    return bits;
}
EXPORT int ccn_cmp(size_t n,const cc_unit *a,const cc_unit *b)
{
    int result=0;
    for(size_t i=0;i<n;i++){int unequal=-(int)(a[i]!=b[i]);int compare=(a[i]>b[i])-(a[i]<b[i]);result=(result&~unequal)|(compare&unequal);}
    return result;
}
EXPORT int ccn_cmpn(size_t na,const cc_unit *a,size_t nb,const cc_unit *b)
{
    size_t common=na<nb?na:nb;int result=ccn_cmp(common,a,b);uint64_t extra=0;
    if(na>nb){for(size_t i=common;i<na;i++)extra|=a[i];return extra?1:result;}
    for(size_t i=common;i<nb;i++)extra|=b[i];return extra?-1:result;
}
EXPORT int ccn_read_uint(size_t n,cc_unit *out,size_t size,const void *input)
{
    const unsigned char *in=input;
    if(n>SIZE_MAX/8)return -7;
    if(size>n*8){
        size_t skip=size-n*8;unsigned excess=0;
        for(size_t i=0;i<skip;i++)excess|=in[i];
        if(excess)return -7;
        in+=skip;size-=skip;
    }
    size_t words=(size+7)/8;
    for(size_t i=0;i<words;i++){
        size_t take=size-i*8;if(take>8)take=8;uint64_t word=0;
        for(size_t j=0;j<take;j++)word|=(uint64_t)in[size-1-i*8-j]<<(j*8);
        out[i]=word;
    }
    for(size_t i=words;i<n;i++)out[i]=0;
    return 0;
}
EXPORT size_t ccn_write_uint_size(size_t n,const cc_unit *a){return (ccn_bitlen(n,a)+7)/8;}
EXPORT size_t ccn_write_int_size(size_t n,const cc_unit *a){size_t bits=ccn_bitlen(n,a);return (bits+7)/8+!(bits&7);}
EXPORT void ccn_write_uint(size_t n,const cc_unit *a,size_t size,void *output)
{
    size_t needed=ccn_write_uint_size(n,a),take=size<needed?size:needed;
    if(!take)return;
    unsigned char *end=(unsigned char *)output+take;
    size_t skip=needed-take,index=skip/8,offset=skip%8;
    cc_unit word=a[index]>>(offset*8);
    while(take>=8){
        size_t chunk=8-offset;
        for(size_t i=0;i<chunk;i++){*--end=(unsigned char)word;word>>=8;}
        take-=chunk;offset=0;
        if(index+1<n)word=a[++index];
    }
    /* A short truncated result stays within its first source word. This
     * preserves the system writer's zero fill after that word runs out. */
    while(take--){*--end=(unsigned char)word;word>>=8;}
}
EXPORT void ccn_write_int(size_t n,const cc_unit *a,size_t size,void *output)
{
    if(!size)return; /* Do not copy the host's write past a zero-byte buffer. */
    unsigned char *out=output;
    if(!(ccn_bitlen(n,a)&7)){*out++=0;size--;}
    ccn_write_uint(n,a,size,out);
}
EXPORT int ccn_write_uint_padded_ct(size_t n,const cc_unit *a,size_t size,void *output)
{
    if(size>INT32_MAX-1 || n>(INT32_MAX-1)/8)return -7;
    size_t needed=ccn_write_uint_size(n,a);
    if(size<needed)return -7;
    unsigned char *out=output;
    for(size_t i=0;i<size;i++){size_t index=size-1-i;out[i]=index/8<n?(unsigned char)(a[index/8]>>((index%8)*8)):0;}
    return (int)(size-needed);
}
EXPORT size_t ccn_write_uint_padded(size_t n,const cc_unit *a,size_t size,void *output)
{
    int result=ccn_write_uint_padded_ct(n,a,size,output);
    if(result<0){ccn_write_uint(n,a,size,output);return 0;}
    return (size_t)result;
}
EXPORT void ccn_zero(size_t n,cc_unit *a){volatile cc_unit *p=a;while(n--)*p++=0;}
EXPORT void ccn_seti(size_t n,cc_unit *a,cc_unit value){if(n){a[0]=value;ccn_zero(n-1,a+1);}}
EXPORT void ccn_set_bit(cc_unit *a,size_t bit,cc_unit value)
{uint64_t mask=UINT64_C(1)<<(bit%64);a[bit/64]=(a[bit/64]&~mask)|(mask&(0-(uint64_t)(value!=0)));}
EXPORT void ccn_swap(size_t n,cc_unit *a)
{
    for(size_t i=0;i<n/2;i++){uint64_t x=__builtin_bswap64(a[i]);a[i]=__builtin_bswap64(a[n-1-i]);a[n-1-i]=x;}
    if(n&1)a[n/2]=__builtin_bswap64(a[n/2]);
}
EXPORT void ccn_xor(size_t n,cc_unit *r,const cc_unit *a,const cc_unit *b){while(n--){r[n]=a[n]^b[n];}}
EXPORT void ccn_print(size_t n,const cc_unit *a){while(n--)fprintf(stderr,"%.016llx",(unsigned long long)a[n]);}
EXPORT void ccn_lprint(size_t n,const char *label,const cc_unit *a){fprintf(stderr,"%s { %zu, ",label,n);ccn_print(n,a);fputs("}\n",stderr);}
