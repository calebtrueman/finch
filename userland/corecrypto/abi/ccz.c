/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccz.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
static size_t used(size_t n,const cc_unit *units)
{while(n&&!units[n-1])n--;return n;}
EXPORT size_t ccz_size(void){return sizeof(struct ccz);}
EXPORT void ccz_init(const struct ccz_class *isa,struct ccz *z)
{z->n=0;z->isa=isa;z->capacity=0;z->units=NULL;}
EXPORT size_t ccz_n(const struct ccz *z){return z->n;}
EXPORT size_t ccz_capacity(const struct ccz *z)
{return z->capacity<0?(size_t)-(int64_t)z->capacity:(size_t)z->capacity;}
EXPORT int ccz_sign(const struct ccz *z){return z->capacity<0?-1:1;}
EXPORT void ccz_set_n(struct ccz *z,size_t n){z->n=n;}
EXPORT void ccz_set_sign(struct ccz *z,int sign)
{if(ccz_sign(z)!=sign)z->capacity=(int32_t)(-(int64_t)z->capacity);}
EXPORT void ccz_set_capacity(struct ccz *z,size_t n)
{
    size_t previous=ccz_capacity(z);
    if(z->units&&n<=previous)return;
    /* The ABI stores capacity in a signed 32-bit field. */
    if(n>(size_t)INT32_MAX-64)abort();
    size_t next=(n&~(size_t)31)+64;
    void *p=previous?z->isa->reallocate(z->isa->context,previous*8,z->units,next*8):z->isa->allocate(z->isa->context,next*8);
    if(!p)abort();
    z->capacity=(int32_t)next*ccz_sign(z);z->units=p;
}
EXPORT void ccz_free(struct ccz *z)
{
    /* Unlike allocation, the free callback receives a word count. */
    if(z->isa&&z->isa->deallocate&&ccz_capacity(z))z->isa->deallocate(z->isa->context,ccz_capacity(z),z->units);
}
EXPORT void ccz_set(struct ccz *z,const struct ccz *value)
{
    if(z==value)return;
    ccz_set_sign(z,ccz_sign(value));ccz_set_capacity(z,value->n);z->n=value->n;
    if(z->n)memmove(z->units,value->units,z->n*8);
}
EXPORT void ccz_seti(struct ccz *z,uint64_t value)
{struct ccz small={value?1:0,NULL,1,0,&value};ccz_set(z,&small);}
EXPORT void ccz_zero(struct ccz *z){ccz_set_sign(z,1);z->n=0;}
EXPORT void ccz_neg(struct ccz *z){if(z->n)ccz_set_sign(z,-ccz_sign(z));}
EXPORT size_t ccz_bitlen(const struct ccz *z){return ccn_bitlen(z->n,z->units);}
EXPORT size_t ccz_trailing_zeros(const struct ccz *z)
{size_t i=0;while(i<z->n&&!z->units[i])i++;return i<z->n?i*64+(size_t)__builtin_ctzll(z->units[i]):0;}
EXPORT bool ccz_is_zero(const struct ccz *z){return !used(z->n,z->units);}
EXPORT bool ccz_is_one(const struct ccz *z){return used(z->n,z->units)==1&&z->units[0]==1;}
EXPORT bool ccz_is_negative(const struct ccz *z){return ccz_sign(z)<0;}
EXPORT int ccz_bit(const struct ccz *z,size_t bit)
{return bit/64<z->n?(int)((z->units[bit/64]>>(bit%64))&1):0;}
EXPORT void ccz_set_bit(struct ccz *z,size_t bit,int value)
{
    size_t n=bit/64+1;
    if(n>z->n){ccz_set_capacity(z,n);memset(z->units+z->n,0,(n-z->n)*8);z->n=n;}
    ccn_set_bit(z->units,bit,(uint32_t)value);
}
EXPORT int ccz_cmp(const struct ccz *a,const struct ccz *b)
{
    int sa=ccz_sign(a),sb=ccz_sign(b);
    if(sa==sb)return sa*ccn_cmpn(a->n,a->units,b->n,b->units);
    if(!a->n&&!b->n)return 0;
    return sa<sb?-1:1;
}
EXPORT int ccz_cmpi(const struct ccz *z,uint32_t input)
{uint64_t value=input;struct ccz small={value?1:0,NULL,1,0,&value};return ccz_cmp(z,&small);}
EXPORT void ccz_read_uint(struct ccz *z,size_t size,const void *input)
{
    if(size>SIZE_MAX-7)abort();
    size_t n=(size+7)/8;ccz_set_sign(z,1);ccz_set_capacity(z,n);
    ccn_read_uint(n,z->units,size,input);z->n=used(n,z->units);
}
EXPORT size_t ccz_write_uint_size(const struct ccz *z){return ccn_write_uint_size(z->n,z->units);}
EXPORT size_t ccz_write_int_size(const struct ccz *z){return ccn_write_int_size(z->n,z->units);}
EXPORT void ccz_write_uint(const struct ccz *z,size_t size,void *output)
{ccn_write_uint_padded(z->n,z->units,size,output);}
EXPORT void ccz_write_int(const struct ccz *z,size_t size,void *output)
{ccn_write_int(z->n,z->units,size,output);}

#include "ccrng.h"
#include <openssl/bn.h>
#include <openssl/crypto.h>
static BIGNUM *magnitude(const struct ccz *z)
{
    if(z->n>INT_MAX/8)abort();
    BIGNUM *value=BN_lebin2bn((const unsigned char *)z->units,(int)(z->n*8),NULL);
    if(!value)abort();return value;
}
static void store_magnitude(struct ccz *z,const BIGNUM *value,size_t width)
{
    if(width>INT_MAX/8)abort();
    ccz_set_capacity(z,width);
    if(BN_bn2lebinpad(value,(unsigned char *)z->units,(int)(width*8))<0)abort();
    z->n=used(width,z->units);
}
static void add_or_sub(struct ccz *z,const struct ccz *a,const struct ccz *b,bool subtract)
{
    size_t na=a->n,nb=b->n;int sa=ccz_sign(a),sb=ccz_sign(b)*(subtract?-1:1);
    bool adding=sa==sb;const struct ccz *larger=a,*smaller=b;int sign=sa;
    if(!adding&&ccn_cmpn(na,a->units,nb,b->units)<0){larger=b;smaller=a;sign=sb;}
    size_t width=adding?(na>nb?na:nb)+1:larger->n;
    ccz_set_sign(z,sign);ccz_set_capacity(z,width);
    /* Low-to-high carries also allow either input to be the output. */
    cc_unit carry=0;
    if(adding){
        size_t n=width-1;
        for(size_t i=0;i<n;i++){
            __uint128_t sum=(__uint128_t)(i<na?a->units[i]:0)+(i<nb?b->units[i]:0)+carry;
            z->units[i]=(cc_unit)sum;carry=(cc_unit)(sum>>64);
        }
        z->units[n]=carry;
    }else{
        size_t nl=larger->n,ns=smaller->n;
        for(size_t i=0;i<nl;i++){
            __uint128_t rhs=(__uint128_t)(i<ns?smaller->units[i]:0)+carry;
            cc_unit lhs=larger->units[i];z->units[i]=lhs-(cc_unit)rhs;carry=(__uint128_t)lhs<rhs;
        }
    }
    z->n=used(width,z->units);
}
EXPORT void ccz_add(struct ccz *z,const struct ccz *a,const struct ccz *b){add_or_sub(z,a,b,false);}
EXPORT void ccz_sub(struct ccz *z,const struct ccz *a,const struct ccz *b){add_or_sub(z,a,b,true);}
EXPORT void ccz_addi(struct ccz *z,const struct ccz *a,uint32_t input)
{cc_unit value=input;struct ccz b={value?1:0,NULL,1,0,&value};ccz_add(z,a,&b);}
EXPORT void ccz_subi(struct ccz *z,const struct ccz *a,uint32_t input)
{cc_unit value=input;struct ccz b={value?1:0,NULL,1,0,&value};ccz_sub(z,a,&b);}
EXPORT void ccz_mul(struct ccz *z,const struct ccz *a,const struct ccz *b)
{
    size_t width=2*(a->n>b->n?a->n:b->n);int sign=ccz_sign(a)*ccz_sign(b);
    BIGNUM *av=magnitude(a),*bv=magnitude(b),*result=BN_new();BN_CTX *ctx=BN_CTX_new();
    if(!result||!ctx||!BN_mul(result,av,bv,ctx))abort();
    ccz_set_sign(z,sign);store_magnitude(z,result,width);
    BN_clear_free(av);BN_clear_free(bv);BN_clear_free(result);BN_CTX_free(ctx);
}
EXPORT void ccz_muli(struct ccz *z,const struct ccz *a,uint32_t input)
{cc_unit value=input;struct ccz b={value?1:0,NULL,1,0,&value};ccz_mul(z,a,&b);}
EXPORT void ccz_lsl(struct ccz *z,const struct ccz *a,size_t bits)
{
    size_t old_n=a->n,words=bits/64,shift=bits%64;
    if(words>SIZE_MAX-old_n-1)abort();
    size_t width=old_n+words+(shift!=0);
    ccz_set_sign(z,ccz_sign(a));ccz_set_capacity(z,width);
    if(old_n)memmove(z->units+words,a->units,old_n*8);
    memset(z->units,0,words*8);z->n=old_n+words;
    if(shift){
        cc_unit carry=0;
        for(size_t i=words;i<z->n;i++){cc_unit v=z->units[i];z->units[i]=(v<<shift)|carry;carry=v>>(64-shift);}
        z->units[z->n]=carry;z->n=used(width,z->units);
    }
}
EXPORT void ccz_lsr(struct ccz *z,const struct ccz *a,size_t bits)
{
    size_t length=ccz_bitlen(a);if(bits>=length){ccz_zero(z);return;}
    size_t words=bits/64,shift=bits%64,width=a->n-words;
    ccz_set_sign(z,ccz_sign(a));ccz_set_capacity(z,width);
    for(size_t i=0;i<width;i++){
        cc_unit value=a->units[i+words]>>shift;
        if(shift&&i+1<width)value|=a->units[i+words+1]<<(64-shift);
        z->units[i]=value;
    }
    z->n=(length-bits+63)/64;
}
EXPORT void ccz_divmod(struct ccz *q,struct ccz *r,const struct ccz *a,const struct ccz *b)
{
    if(ccz_is_zero(b))return;
    if(ccn_cmpn(a->n,a->units,b->n,b->units)<0){if(r)ccz_set(r,a);if(q)ccz_zero(q);return;}
    int sa=ccz_sign(a),sb=ccz_sign(b);
    BIGNUM *av=magnitude(a),*bv=magnitude(b),*quot=BN_new(),*rem=BN_new();BN_CTX *ctx=BN_CTX_new();
    if(!quot||!rem||!ctx||!BN_div(quot,rem,av,bv,ctx))abort();
    if(r){store_magnitude(r,rem,((size_t)BN_num_bits(rem)+63)/64);ccz_set_sign(r,r->n?sa:1);}
    if(q){store_magnitude(q,quot,((size_t)BN_num_bits(quot)+63)/64);ccz_set_sign(q,q->n?sa*sb:1);}
    BN_clear_free(av);BN_clear_free(bv);BN_clear_free(quot);BN_clear_free(rem);BN_CTX_free(ctx);
}
EXPORT void ccz_mod(struct ccz *z,const struct ccz *a,const struct ccz *m){ccz_divmod(NULL,z,a,m);}
EXPORT void ccz_mulmod(struct ccz *z,const struct ccz *a,const struct ccz *b,const struct ccz *m)
{ccz_mul(z,a,b);ccz_mod(z,z,m);}
EXPORT int ccz_expmod(struct ccz *z,const struct ccz *a,const struct ccz *e,const struct ccz *m)
{
    size_t width=m->n;BIGNUM *av=magnitude(a),*ev=magnitude(e),*mv=magnitude(m),*result=BN_new();BN_CTX *ctx=BN_CTX_new();
    if(!result||!ctx)abort();ccz_set_capacity(z,width);
    int status=-7;
    if(!BN_is_zero(mv)&&!BN_is_one(mv)&&BN_is_odd(mv)){
        if(BN_mod_exp_mont_consttime(result,av,ev,mv,ctx,NULL)){store_magnitude(z,result,width);status=0;}else status=-1;
    }
    BN_clear_free(av);BN_clear_free(ev);BN_clear_free(mv);BN_clear_free(result);BN_CTX_free(ctx);return status;
}
EXPORT bool ccz_is_prime(const struct ccz *z,unsigned rounds)
{
    (void)rounds;BIGNUM *value=magnitude(z);BN_CTX *ctx=BN_CTX_new();if(!ctx)abort();
    bool prime=BN_check_prime(value,ctx,NULL)==1;BN_clear_free(value);BN_CTX_free(ctx);return prime;
}
EXPORT int ccz_random_bits(struct ccz *z,size_t bits,struct ccrng_state *rng)
{
    if(bits>SIZE_MAX-63)return -7;
    size_t n=(bits+63)/64;ccz_set_sign(z,1);ccz_set_capacity(z,n);
    int result=rng->generate(rng,n*8,z->units);
    if(!result&&n&&(bits%64))z->units[n-1]&=(UINT64_C(1)<<(bits%64))-1;
    z->n=used(n,z->units);return result;
}
EXPORT int ccz_read_radix(struct ccz *z,size_t size,const char *input,unsigned radix)
{
    if(radix!=10&&radix!=16)return -45;
    if(!size)return -7;
    int sign=1;
    if(*input=='-'||*input=='+'){sign=*input=='-'?-1:1;input++;if(!--size)return -7;}
    while(size&&*input=='0'){input++;size--;}
    if(size>(SIZE_MAX-63)/4)return -7;
    size_t width=(size*4+63)/64;ccz_set_capacity(z,width);z->n=width;
    if(width)memset(z->units,0,width*8);ccz_set_sign(z,sign);
    if(radix==10){
        for(size_t j=0;j<size;j++){
            unsigned digit=(unsigned char)input[j]-'0';if(digit>9)return -44;
            cc_unit carry=digit;
            for(size_t i=0;i<width;i++){__uint128_t value=(__uint128_t)z->units[i]*10+carry;z->units[i]=(cc_unit)value;carry=(cc_unit)(value>>64);}
        }
        z->n=used(width,z->units);
    }else{
        for(size_t j=0;j<size;j++){
            unsigned c=(unsigned char)input[size-1-j],digit;
            if(c>='0'&&c<='9')digit=c-'0';else if(c>='a'&&c<='f')digit=c-'a'+10;else if(c>='A'&&c<='F')digit=c-'A'+10;else return -44;
            z->units[j/16]|=(cc_unit)digit<<((j%16)*4);
        }
    }
    if(ccz_is_zero(z))ccz_set_sign(z,1);return 0;
}
static char *decimal_magnitude(const struct ccz *z)
{BIGNUM *value=magnitude(z);char *text=BN_bn2dec(value);BN_clear_free(value);if(!text)abort();return text;}
EXPORT size_t ccz_write_radix_size(const struct ccz *z,unsigned radix)
{
    if(radix!=10&&radix!=16)return 0;
    if(ccz_is_zero(z))return 1;
    size_t size;
    if(radix==16)size=(ccz_bitlen(z)+3)/4;
    else{char *text=decimal_magnitude(z);size=strlen(text);OPENSSL_clear_free(text,size+1);}
    return size+(ccz_sign(z)<0);
}
EXPORT int ccz_write_radix(const struct ccz *z,size_t size,char *output,unsigned radix)
{
    if(radix!=10&&radix!=16)return -45;
    if(!size)return -7;
    if(!ccz_is_zero(z)&&ccz_sign(z)<0){if(size==1)return -7;*output++='-';size--;}
    memset(output,'0',size);
    if(radix==16){
        static const char digits[]="0123456789ABCDEF";
        size_t nibbles=(ccz_bitlen(z)+3)/4,take=nibbles<size?nibbles:size;
        for(size_t i=0;i<take;i++)output[size-1-i]=digits[(z->units[i/16]>>((i%16)*4))&15];
    }else{
        char *text=decimal_magnitude(z);size_t length=strlen(text),take=length<size?length:size;
        memcpy(output+size-take,text+length-take,take);OPENSSL_clear_free(text,length+1);
    }
    return 0;
}
