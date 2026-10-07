/* SPDX-License-Identifier: MIT OR Apache-2.0
 * DER headers and bounded byte ranges. Encoders work backwards from end;
 * decoders move start forwards. Failed compound calls retain earlier progress,
 * as callers observe with the system library.
 */
#include "ccder.h"
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
#define TAG_NUMBER UINT64_C(0x1fffffffffffffff)
static size_t available(const struct ccder_blob *b)
{ return (uintptr_t)b->end >= (uintptr_t)b->start ? (uintptr_t)b->end-(uintptr_t)b->start : 0; }
EXPORT size_t ccder_sizeof_tag(ccder_tag tag)
{
    tag &= TAG_NUMBER;
    return tag<31?1:tag<128?2:tag<(UINT64_C(1)<<14)?3:tag<(UINT64_C(1)<<21)?4:tag<(UINT64_C(1)<<28)?5:6;
}
EXPORT size_t ccder_sizeof_len(size_t size)
{ if(size<128)return 1;size_t bytes=1;while(size){bytes++;size>>=8;}return bytes; }
EXPORT size_t ccder_sizeof(ccder_tag tag,size_t size)
{ return size+ccder_sizeof_tag(tag)+ccder_sizeof_len(size); }
EXPORT size_t ccder_sizeof_overflow(ccder_tag tag,size_t size,bool *overflow)
{
    if(*overflow)return 0;
    size_t result;*overflow=__builtin_add_overflow(size,ccder_sizeof_tag(tag)+ccder_sizeof_len(size),&result);
    return result;
}
EXPORT bool ccder_blob_encode_tag(struct ccder_blob *b,ccder_tag tag)
{
    size_t bytes=ccder_sizeof_tag(tag);if(available(b)<bytes)return false;
    unsigned char *p=b->end-bytes;
    if(bytes==1)p[0]=(unsigned char)(((tag>>56)&0xe0)|(tag&31));
    else {
        p[0]=(unsigned char)((tag>>56)|31);
        for(size_t i=1;i<bytes;i++){
            unsigned shift=(unsigned)((bytes-1-i)*7);
            p[i]=(unsigned char)((tag>>shift)&127);
            if(i<bytes-1)p[i]|=128;
        }
        /* The host reserves at most five base-128 bytes, including for larger
         * tag values. Its first group keeps the low byte of tag >> 28. */
        if(bytes==6)p[1]=(unsigned char)((tag>>28)|128);
    }
    b->end=p;return true;
}
EXPORT bool ccder_blob_encode_len(struct ccder_blob *b,size_t size)
{
    if(size>UINT32_MAX)return false;
    size_t bytes=ccder_sizeof_len(size);if(available(b)<bytes)return false;
    unsigned char *p=b->end-bytes;
    if(bytes==1)p[0]=(unsigned char)size;
    else {p[0]=(unsigned char)(128+bytes-1);for(size_t i=1;i<bytes;i++)p[i]=(unsigned char)(size>>((bytes-1-i)*8));}
    b->end=p;return true;
}
EXPORT bool ccder_blob_encode_tl(struct ccder_blob *b,ccder_tag tag,size_t size)
{ return ccder_blob_encode_len(b,size)&&ccder_blob_encode_tag(b,tag); }
EXPORT bool ccder_blob_reserve(struct ccder_blob *b,size_t size,struct ccder_blob *out)
{
    if(available(b)<size){out->start=NULL;out->end=NULL;return false;}
    unsigned char *end=b->end;b->end-=size;out->start=b->end;out->end=end;return true;
}
EXPORT bool ccder_blob_reserve_tl(struct ccder_blob *b,ccder_tag tag,size_t size,struct ccder_blob *out)
{
    struct ccder_blob body;out->start=NULL;out->end=NULL;
    if(!ccder_blob_reserve(b,size,&body)||!ccder_blob_encode_tl(b,tag,size))return false;
    *out=body;return true;
}
EXPORT bool ccder_blob_encode_body(struct ccder_blob *b,size_t size,const void *body)
{
    if(!body)return !size;
    struct ccder_blob region;if(!ccder_blob_reserve(b,size,&region))return false;
    memmove(region.start,body,size);return true;
}
EXPORT bool ccder_blob_encode_body_tl(struct ccder_blob *b,ccder_tag tag,size_t size,const void *body)
{ return ccder_blob_encode_body(b,size,body)&&ccder_blob_encode_tl(b,tag,size); }
EXPORT bool ccder_blob_decode_tag(struct ccder_read_blob *b,ccder_tag *out)
{
    const unsigned char *p=b->start;
    if(!p||p>=b->end)return false;
    unsigned char first=*p++;uint64_t tag=first&31;
    if(tag==31){
        tag=0;
        for(;;){
            if(p>=b->end || tag>>57)return false;
            unsigned char byte=*p++;uint64_t previous=tag;
            tag=(tag<<7)|(byte&127);
            if(!(byte&128)){if(previous>>54)return false;break;}
        }
    }
    *out=tag|((uint64_t)(first>>5)<<61);b->start=p;return true;
}
static bool decode_len(struct ccder_read_blob *b,size_t *out,bool strict)
{
    *out=0;const unsigned char *p=b->start;
    if(!p||p>=b->end)return false;
    unsigned char first=*p++;size_t size=first;
    if(first&128){
        size_t count=first&127;if(!count||count>4||(size_t)(b->end-p)<count)return false;
        if(strict&&((count==1&&*p<128)||(count>1&&!*p)))return false;
        size=0;for(size_t i=0;i<count;i++)size=(size<<8)|*p++;
    }
    if(size>(size_t)(b->end-p))return false;
    *out=size;b->start=p;return true;
}
static bool decode_tl(struct ccder_read_blob *b,ccder_tag expected,size_t *out,bool strict)
{
    ccder_tag actual;*out=0;
    return ccder_blob_decode_tag(b,&actual)&&actual==expected&&decode_len(b,out,strict);
}
static bool decode_range(struct ccder_read_blob *b,ccder_tag tag,struct ccder_read_blob *out,bool strict)
{
    size_t size;if(!decode_tl(b,tag,&size,strict)){out->start=NULL;out->end=NULL;return false;}
    const unsigned char *start=b->start,*end=start+size;
    b->start=end;out->start=start;out->end=end;return true;
}
#define DECODE(suffix,strict) \
EXPORT bool ccder_blob_decode_len##suffix(struct ccder_read_blob *b,size_t *out){return decode_len(b,out,strict);} \
EXPORT bool ccder_blob_decode_tl##suffix(struct ccder_read_blob *b,ccder_tag tag,size_t *out){return decode_tl(b,tag,out,strict);} \
EXPORT bool ccder_blob_decode_range##suffix(struct ccder_read_blob *b,ccder_tag tag,struct ccder_read_blob *out){return decode_range(b,tag,out,strict);} \
EXPORT bool ccder_blob_decode_sequence_tl##suffix(struct ccder_read_blob *b,struct ccder_read_blob *out){return decode_range(b,CCDER_SEQUENCE,out,strict);} \
EXPORT const unsigned char *ccder_decode_len##suffix(size_t *out,const unsigned char *start,const unsigned char *end) \
{if(!start)return NULL;struct ccder_read_blob b={start,end};return decode_len(&b,out,strict)?b.start:NULL;} \
EXPORT const unsigned char *ccder_decode_tl##suffix(ccder_tag tag,size_t *out,const unsigned char *start,const unsigned char *end) \
{if(!start)return NULL;struct ccder_read_blob b={start,end};return decode_tl(&b,tag,out,strict)?b.start:NULL;} \
EXPORT const unsigned char *ccder_decode_constructed_tl##suffix(ccder_tag tag,const unsigned char **body_end,const unsigned char *start,const unsigned char *end) \
{*body_end=start;if(!start)return NULL;struct ccder_read_blob b={start,end},body;if(!decode_range(&b,tag,&body,strict))return NULL;*body_end=body.end;return body.start;} \
EXPORT const unsigned char *ccder_decode_sequence_tl##suffix(const unsigned char **body_end,const unsigned char *start,const unsigned char *end) \
{return ccder_decode_constructed_tl##suffix(CCDER_SEQUENCE,body_end,start,end);}
DECODE(,false)
DECODE(_strict,true)
EXPORT const unsigned char *ccder_decode_tag(ccder_tag *tag,const unsigned char *start,const unsigned char *end)
{if(!start)return NULL;struct ccder_read_blob b={start,end};return ccder_blob_decode_tag(&b,tag)?b.start:NULL;}
EXPORT unsigned char *ccder_encode_tag(ccder_tag tag,unsigned char *start,unsigned char *end)
{if(!end)return NULL;struct ccder_blob b={start,end};return ccder_blob_encode_tag(&b,tag)?b.end:NULL;}
EXPORT unsigned char *ccder_encode_len(size_t size,unsigned char *start,unsigned char *end)
{if(!end)return NULL;struct ccder_blob b={start,end};return ccder_blob_encode_len(&b,size)?b.end:NULL;}
EXPORT unsigned char *ccder_encode_tl(ccder_tag tag,size_t size,unsigned char *start,unsigned char *end)
{if(!end)return NULL;struct ccder_blob b={start,end};return ccder_blob_encode_tl(&b,tag,size)?b.end:NULL;}
EXPORT unsigned char *ccder_encode_body(size_t size,const void *body,unsigned char *start,unsigned char *end)
{if(!end)return NULL;struct ccder_blob b={start,end};return ccder_blob_encode_body(&b,size,body)?b.end:NULL;}
EXPORT unsigned char *ccder_encode_body_nocopy(size_t size,unsigned char *start,unsigned char *end)
{if(!end)return NULL;struct ccder_blob b={start,end},body;return ccder_blob_reserve(&b,size,&body)?b.end:NULL;}
EXPORT unsigned char *ccder_encode_constructed_tl(ccder_tag tag,const unsigned char *body_end,unsigned char *start,unsigned char *end)
{ return ccder_encode_tl(tag,(size_t)(body_end-end),start,end); }

/* INTEGER values are unsigned, with DER's leading sign byte removed. */
#include "ccn.h"
static bool positive_integer(struct ccder_read_blob *value)
{
    if(value->start==value->end || (*value->start&128))return false;
    if(!*value->start){
        value->start++;
        if(value->start!=value->end && !(*value->start&128))return false;
    }
    return true;
}
#define INTEGER_DECODE(suffix,strict) \
EXPORT bool ccder_blob_decode_uint##suffix(struct ccder_read_blob *b,size_t n,cc_unit *out) \
{struct ccder_read_blob v;return decode_range(b,2,&v,strict)&&positive_integer(&v)&&!ccn_read_uint(n,out,(size_t)(v.end-v.start),v.start);} \
EXPORT const unsigned char *ccder_decode_uint##suffix(size_t n,cc_unit *out,const unsigned char *start,const unsigned char *end) \
{if(!start)return NULL;struct ccder_read_blob b={start,end};return ccder_blob_decode_uint##suffix(&b,n,out)?b.start:NULL;}
INTEGER_DECODE(,false)
INTEGER_DECODE(_strict,true)
EXPORT bool ccder_blob_decode_uint_n(struct ccder_read_blob *b,size_t *n)
{
    struct ccder_read_blob v;if(!decode_range(b,2,&v,false)||!positive_integer(&v))return false;
    *n=((size_t)(v.end-v.start)+7)/8;return true;
}
EXPORT bool ccder_blob_decode_uint64(struct ccder_read_blob *b,uint64_t *out)
{
    if(out)*out=0;
    struct ccder_read_blob v;if(!decode_range(b,2,&v,false)||!positive_integer(&v)||(size_t)(v.end-v.start)>8)return false;
    uint64_t x=0;while(v.start<v.end)x=(x<<8)|*v.start++;
    if(out)*out=x;return true;
}
EXPORT const unsigned char *ccder_decode_uint_n(size_t *n,const unsigned char *start,const unsigned char *end)
{if(!start)return NULL;struct ccder_read_blob b={start,end};return ccder_blob_decode_uint_n(&b,n)?b.start:NULL;}
EXPORT const unsigned char *ccder_decode_uint64(uint64_t *out,const unsigned char *start,const unsigned char *end)
{if(!start)return NULL;struct ccder_read_blob b={start,end};return ccder_blob_decode_uint64(&b,out)?b.start:NULL;}
EXPORT size_t ccder_sizeof_implicit_integer(ccder_tag tag,size_t n,const cc_unit *value)
{return ccder_sizeof(tag,ccn_write_int_size(n,value));}
EXPORT size_t ccder_sizeof_integer(size_t n,const cc_unit *value)
{return ccder_sizeof_implicit_integer(2,n,value);}
EXPORT size_t ccder_sizeof_implicit_octet_string(ccder_tag tag,size_t n,const cc_unit *value)
{return ccder_sizeof(tag,ccn_write_uint_size(n,value));}
EXPORT size_t ccder_sizeof_octet_string(size_t n,const cc_unit *value)
{return ccder_sizeof_implicit_octet_string(4,n,value);}
EXPORT size_t ccder_sizeof_implicit_uint64(ccder_tag tag,uint64_t value)
{return ccder_sizeof_implicit_integer(tag,1,&value);}
EXPORT size_t ccder_sizeof_uint64(uint64_t value)
{return ccder_sizeof_implicit_uint64(2,value);}
EXPORT size_t ccder_sizeof_implicit_raw_octet_string(ccder_tag tag,size_t size)
{return ccder_sizeof(tag,size);}
EXPORT size_t ccder_sizeof_raw_octet_string(size_t size)
{return ccder_sizeof(4,size);}
EXPORT size_t ccder_sizeof_implicit_raw_octet_string_overflow(ccder_tag tag,size_t size,bool *overflow)
{return ccder_sizeof_overflow(tag,size,overflow);}
EXPORT bool ccder_blob_encode_implicit_integer(struct ccder_blob *b,ccder_tag tag,size_t n,const cc_unit *value)
{
    size_t size=ccn_write_int_size(n,value);struct ccder_blob body;
    if(!ccder_blob_reserve_tl(b,tag,size,&body))return false;
    ccn_write_int(n,value,size,body.start);return true;
}
EXPORT bool ccder_blob_encode_integer(struct ccder_blob *b,size_t n,const cc_unit *value)
{return ccder_blob_encode_implicit_integer(b,2,n,value);}
EXPORT bool ccder_blob_encode_implicit_octet_string(struct ccder_blob *b,ccder_tag tag,size_t n,const cc_unit *value)
{
    size_t size=ccn_write_uint_size(n,value);struct ccder_blob body;
    if(!ccder_blob_reserve_tl(b,tag,size,&body))return false;
    /* The system API uses the signed writer even for this unsigned size.
     * Preserve its truncation, but never write beyond a zero-length body. */
    if(size)ccn_write_int(n,value,size,body.start);return true;
}
EXPORT bool ccder_blob_encode_octet_string(struct ccder_blob *b,size_t n,const cc_unit *value)
{return ccder_blob_encode_implicit_octet_string(b,4,n,value);}
EXPORT bool ccder_blob_encode_implicit_uint64(struct ccder_blob *b,ccder_tag tag,uint64_t value)
{return ccder_blob_encode_implicit_integer(b,tag,1,&value);}
EXPORT bool ccder_blob_encode_uint64(struct ccder_blob *b,uint64_t value)
{return ccder_blob_encode_implicit_uint64(b,2,value);}
EXPORT bool ccder_blob_encode_implicit_raw_octet_string(struct ccder_blob *b,ccder_tag tag,size_t size,const void *value)
{return ccder_blob_encode_body_tl(b,tag,size,value);}
EXPORT bool ccder_blob_encode_raw_octet_string(struct ccder_blob *b,size_t size,const void *value)
{return ccder_blob_encode_body_tl(b,4,size,value);}
#define ENCODE_NUMBER(name) \
EXPORT unsigned char *ccder_encode_implicit_##name(ccder_tag tag,size_t n,const cc_unit *value,unsigned char *start,unsigned char *end) \
{if(!end)return NULL;struct ccder_blob b={start,end};return ccder_blob_encode_implicit_##name(&b,tag,n,value)?b.end:NULL;} \
EXPORT unsigned char *ccder_encode_##name(size_t n,const cc_unit *value,unsigned char *start,unsigned char *end) \
{if(!end)return NULL;struct ccder_blob b={start,end};return ccder_blob_encode_##name(&b,n,value)?b.end:NULL;}
ENCODE_NUMBER(integer)
ENCODE_NUMBER(octet_string)
EXPORT unsigned char *ccder_encode_implicit_uint64(ccder_tag tag,uint64_t value,unsigned char *start,unsigned char *end)
{if(!end)return NULL;struct ccder_blob b={start,end};return ccder_blob_encode_implicit_uint64(&b,tag,value)?b.end:NULL;}
EXPORT unsigned char *ccder_encode_uint64(uint64_t value,unsigned char *start,unsigned char *end)
{return ccder_encode_implicit_uint64(2,value,start,end);}
EXPORT unsigned char *ccder_encode_implicit_raw_octet_string(ccder_tag tag,size_t size,const void *value,unsigned char *start,unsigned char *end)
{if(!end)return NULL;struct ccder_blob b={start,end};return ccder_blob_encode_implicit_raw_octet_string(&b,tag,size,value)?b.end:NULL;}
EXPORT unsigned char *ccder_encode_raw_octet_string(size_t size,const void *value,unsigned char *start,unsigned char *end)
{return ccder_encode_implicit_raw_octet_string(4,size,value,start,end);}
EXPORT size_t ccder_sizeof_oid(const unsigned char *oid)
{return oid?(size_t)oid[1]+2:0;}
EXPORT bool ccder_blob_encode_oid(struct ccder_blob *b,const unsigned char *oid)
{return ccder_blob_encode_body(b,ccder_sizeof_oid(oid),oid);}
EXPORT unsigned char *ccder_encode_oid(const unsigned char *oid,unsigned char *start,unsigned char *end)
{if(!end)return NULL;struct ccder_blob b={start,end};return ccder_blob_encode_oid(&b,oid)?b.end:NULL;}
EXPORT bool ccder_blob_decode_oid(struct ccder_read_blob *b,const unsigned char **oid)
{
    const unsigned char *start=b->start;struct ccder_read_blob v;
    bool ok=decode_range(b,6,&v,false);*oid=ok?start:NULL;return ok;
}
EXPORT const unsigned char *ccder_decode_oid(const unsigned char **oid,const unsigned char *start,const unsigned char *end)
{*oid=NULL;if(!start)return NULL;struct ccder_read_blob b={start,end};return ccder_blob_decode_oid(&b,oid)?b.start:NULL;}
EXPORT bool ccder_blob_decode_bitstring(struct ccder_read_blob *b,struct ccder_read_blob *value,size_t *bits)
{
    if(!decode_range(b,3,value,false))return false;
    *bits=0;
    if(value->start!=value->end){size_t unused=*value->start++,size=(size_t)(value->end-value->start)*8;if(size>=unused)*bits=size-unused;}
    return true;
}
EXPORT const unsigned char *ccder_decode_bitstring(const unsigned char **value,size_t *bits,const unsigned char *start,const unsigned char *end)
{
    if(!start)return NULL;struct ccder_read_blob b={start,end},v;
    if(!ccder_blob_decode_bitstring(&b,&v,bits)){*value=NULL;*bits=0;return NULL;}
    *value=v.start;return b.start;
}
#define SEQII(suffix) \
EXPORT bool ccder_blob_decode_seqii##suffix(struct ccder_read_blob *b,size_t n,cc_unit *r,cc_unit *s) \
{struct ccder_read_blob v;return ccder_blob_decode_sequence_tl##suffix(b,&v)&&ccder_blob_decode_uint##suffix(&v,n,r)&&ccder_blob_decode_uint##suffix(&v,n,s)&&v.start==v.end;} \
EXPORT const unsigned char *ccder_decode_seqii##suffix(size_t n,cc_unit *r,cc_unit *s,const unsigned char *start,const unsigned char *end) \
{if(!start)return NULL;struct ccder_read_blob b={start,end};return ccder_blob_decode_seqii##suffix(&b,n,r,s)?b.start:NULL;}
SEQII()
SEQII(_strict)
#define EC_PARAMETERS UINT64_C(0xa000000000000000)
#define EC_PUBLIC_KEY UINT64_C(0xa000000000000001)
EXPORT size_t ccder_sizeof_eckey(size_t private_size,const unsigned char *oid,size_t public_size)
{
    size_t size=ccder_sizeof_uint64(1)+ccder_sizeof(4,private_size);
    if(oid)size+=ccder_sizeof(EC_PARAMETERS,ccder_sizeof_oid(oid));
    if(public_size)size+=ccder_sizeof(EC_PUBLIC_KEY,ccder_sizeof(3,public_size+1));
    return ccder_sizeof(CCDER_SEQUENCE,size);
}
EXPORT size_t ccder_encode_eckey_size(size_t private_size,const unsigned char *oid,size_t public_size)
{return ccder_sizeof_eckey(private_size,oid,public_size);}
EXPORT bool ccder_blob_encode_eckey(struct ccder_blob *b,size_t private_size,const void *private_key,const unsigned char *oid,size_t public_size,const void *public_key)
{
    if(!private_size)return false;
    const unsigned char *end=b->end;
    if(public_size&&public_key){
        const unsigned char zero=0;
        if(!ccder_blob_encode_body(b,public_size,public_key)||!ccder_blob_encode_body(b,1,&zero)||
           !ccder_blob_encode_tl(b,3,(size_t)(end-b->end))||!ccder_blob_encode_tl(b,EC_PUBLIC_KEY,(size_t)(end-b->end)))return false;
    }
    if(oid){const unsigned char *field_end=b->end;if(!ccder_blob_encode_oid(b,oid)||!ccder_blob_encode_tl(b,EC_PARAMETERS,(size_t)(field_end-b->end)))return false;}
    return ccder_blob_encode_raw_octet_string(b,private_size,private_key)&&ccder_blob_encode_uint64(b,1)&&ccder_blob_encode_tl(b,CCDER_SEQUENCE,(size_t)(end-b->end));
}
EXPORT unsigned char *ccder_encode_eckey(size_t private_size,const void *private_key,const unsigned char *oid,size_t public_size,const void *public_key,unsigned char *start,unsigned char *end)
{struct ccder_blob b={start,end};return ccder_blob_encode_eckey(&b,private_size,private_key,oid,public_size,public_key)?b.end:NULL;}
EXPORT bool ccder_blob_decode_eckey(struct ccder_read_blob *b,uint64_t *version,size_t *private_size,const unsigned char **private_key,const unsigned char **oid,size_t *public_size,const unsigned char **public_key,size_t *public_bits)
{
    struct ccder_read_blob seq,field,trial;
    if(!ccder_blob_decode_sequence_tl(b,&seq)||!ccder_blob_decode_uint64(&seq,version)||*version!=1||!decode_range(&seq,4,&field,false))return false;
    *private_key=field.start;*private_size=(size_t)(field.end-field.start);
    trial=seq;
    if(decode_range(&trial,EC_PARAMETERS,&field,false)){
        if(!ccder_blob_decode_oid(&field,oid))return false;
        seq=trial;
    }else *oid=NULL;
    trial=seq;
    if(decode_range(&trial,EC_PUBLIC_KEY,&field,false)){
        if(!ccder_blob_decode_bitstring(&field,&field,public_bits))return false;
        *public_key=field.start;*public_size=(size_t)(field.end-field.start);
    }else{*public_key=NULL;*public_size=0;*public_bits=0;}
    return true;
}
EXPORT const unsigned char *ccder_decode_eckey(uint64_t *version,size_t *private_size,const unsigned char **private_key,const unsigned char **oid,size_t *public_bits,const unsigned char **public_key,const unsigned char *start,const unsigned char *end)
{struct ccder_read_blob b={start,end};size_t public_size;return ccder_blob_decode_eckey(&b,version,private_size,private_key,oid,&public_size,public_key,public_bits)?b.start:NULL;}
EXPORT size_t ccder_decode_rsa_pub_n(const unsigned char *start,const unsigned char *end)
{
    const unsigned char *seq_end;size_t n;
    const unsigned char *p=ccder_decode_sequence_tl(&seq_end,start,end);
    return p&&ccder_decode_uint_n(&n,p,seq_end)?n:0;
}
EXPORT size_t ccder_decode_dhparam_n(const unsigned char *start,const unsigned char *end)
{return ccder_decode_rsa_pub_n(start,end);}
EXPORT size_t ccder_decode_rsa_priv_n(const unsigned char *start,const unsigned char *end)
{
    const unsigned char *seq_end;size_t n;cc_unit version;
    const unsigned char *p=ccder_decode_sequence_tl(&seq_end,start,end);
    if(!p||!(p=ccder_decode_uint(1,&version,p,seq_end))||version)return 0;
    return ccder_decode_uint_n(&n,p,seq_end)?n:0;
}
EXPORT size_t ccder_decode_rsa_pub_x509_n(const unsigned char *start,const unsigned char *end)
{
    const unsigned char *seq_end,*field_end,*oid;
    const unsigned char *p=ccder_decode_sequence_tl(&seq_end,start,end);
    if(!p||!(p=ccder_decode_sequence_tl(&field_end,p,seq_end))||!(p=ccder_decode_oid(&oid,p,field_end)))return 0;
    p=ccder_decode_constructed_tl(5,&field_end,p,field_end);
    if(!p||!(p=ccder_decode_constructed_tl(3,&field_end,p,seq_end)))return 0;
    if(p<field_end&&!*p)p++;
    return ccder_decode_rsa_pub_n(p,field_end);
}
