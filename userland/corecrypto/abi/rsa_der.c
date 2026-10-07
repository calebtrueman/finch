/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccrsa.h"
#include "ccder.h"
#include <stdlib.h>
#include <string.h>
#define API __attribute__((visibility("default")))
API const unsigned char *ccder_decode_rsa_pub(ccrsa_ctx*k,const unsigned char*b,const unsigned char*e){
 const unsigned char*end;const unsigned char*p=ccder_decode_sequence_tl(&end,b,e);if(!p)return NULL;
 p=ccder_decode_uint(k->n,k->data,p,end);if(!p)return NULL;
 p=ccder_decode_uint(k->n,finch_rsa_e(k),p,end);return p&&!finch_cczp_init(k,1)?p:NULL;
}
API const unsigned char *ccder_decode_rsa_pub_x509(ccrsa_ctx*k,const unsigned char*b,const unsigned char*e){
 const unsigned char*end,*alg,*bits;size_t n;const unsigned char*p=ccder_decode_sequence_tl(&end,b,e);if(!p)return NULL;
 p=ccder_decode_sequence_tl(&alg,p,end);if(!p)return NULL;
 p=ccder_decode_bitstring(&bits,&n,alg,end);if(!p||n%8)return NULL;
 return ccder_decode_rsa_pub(k,bits,bits+n/8);
}
API const unsigned char *ccder_decode_rsa_priv(ccrsa_ctx*k,const unsigned char*b,const unsigned char*e){
 const unsigned char*end;uint64_t v;const unsigned char*s=ccder_decode_sequence_tl(&end,b,e);if(!s)return NULL;
 s=ccder_decode_uint64(&v,s,end);if(!s||v)return NULL;
 s=ccder_decode_uint(k->n,k->data,s,end);if(!s)return NULL;
 s=ccder_decode_uint(k->n,finch_rsa_e(k),s,end);if(!s)return NULL;
 s=ccder_decode_uint(k->n,finch_rsa_d(k),s,end);if(!s||finch_cczp_init(k,1))return NULL;
 size_t cap=k->n/2+1;cc_unit*t=calloc(cap,8);if(!t)return NULL;
 s=ccder_decode_uint(cap,t,s,end);if(!s){free(t);return NULL;}struct cczp*p=finch_rsa_p(k);p->n=(ccn_bitlen(cap,t)+63)/64;memcpy(p->data,t,p->n*8);if(finch_cczp_init(p,0)){free(t);return NULL;}
 s=ccder_decode_uint(cap,t,s,end);if(!s){free(t);return NULL;}struct cczp*q=finch_rsa_q(k);q->n=(ccn_bitlen(cap,t)+63)/64;memcpy(q->data,t,q->n*8);free(t);if(finch_cczp_init(q,0)||p->bitlen<q->bitlen)return NULL;
 s=ccder_decode_uint(p->n,finch_rsa_dp(k),s,end);if(!s)return NULL;
 s=ccder_decode_uint(q->n,finch_rsa_dq(k),s,end);if(!s)return NULL;
 return ccder_decode_uint(p->n,finch_rsa_qinv(k),s,end);
}
API size_t ccder_encode_rsa_pub_size(const ccrsa_ctx*k){return ccder_sizeof(CCDER_SEQUENCE,ccder_sizeof_integer(k->n,k->data)+ccder_sizeof_integer(k->n,finch_rsa_e(k)));}
API unsigned char *ccder_encode_rsa_pub(const ccrsa_ctx*k,unsigned char*b,unsigned char*e){unsigned char*p=ccder_encode_integer(k->n,finch_rsa_e(k),b,e);if(!p)return NULL;p=ccder_encode_integer(k->n,k->data,b,p);return p?ccder_encode_constructed_tl(CCDER_SEQUENCE,e,b,p):NULL;}
static size_t parts(const ccrsa_ctx*k,const cc_unit**v,size_t*n){struct cczp*p=finch_rsa_p(k),*q=finch_rsa_q(k);v[0]=k->data;v[1]=finch_rsa_e(k);v[2]=finch_rsa_d(k);v[3]=p->data;v[4]=q->data;v[5]=finch_rsa_dp(k);v[6]=finch_rsa_dq(k);v[7]=finch_rsa_qinv(k);n[0]=n[1]=n[2]=k->n;n[3]=n[5]=n[7]=p->n;n[4]=n[6]=q->n;return 8;}
API size_t ccder_encode_rsa_priv_size(const ccrsa_ctx*k){const cc_unit*v[8];size_t n[8],s=ccder_sizeof_uint64(0);parts(k,v,n);for(int i=0;i<8;i++)s+=ccder_sizeof_integer(n[i],v[i]);return ccder_sizeof(CCDER_SEQUENCE,s);}
API unsigned char *ccder_encode_rsa_priv(const ccrsa_ctx*k,unsigned char*b,unsigned char*e){const cc_unit*v[8];size_t n[8];parts(k,v,n);unsigned char*p=e;for(int i=7;i>=0&&p;i--)p=ccder_encode_integer(n[i],v[i],b,p);if(p)p=ccder_encode_uint64(0,b,p);return p?ccder_encode_constructed_tl(CCDER_SEQUENCE,e,b,p):NULL;}
API size_t ccrsa_export_pub_size(const ccrsa_ctx*k){return ccder_encode_rsa_pub_size(k);}
API size_t ccrsa_export_priv_size(const ccrsa_ctx*k){return ccder_encode_rsa_priv_size(k);}
API int ccrsa_export_pub(const ccrsa_ctx*k,size_t n,unsigned char*b){return ccder_encode_rsa_pub(k,b,b+n)!=b;}
API int ccrsa_export_priv(const ccrsa_ctx*k,size_t n,unsigned char*b){return ccder_encode_rsa_priv(k,b,b+n)!=b;}
API size_t ccrsa_import_pub_n(size_t n,const unsigned char*b){size_t r=ccder_decode_rsa_pub_x509_n(b,b+n);return r?r:ccder_decode_rsa_pub_n(b,b+n);}
API size_t ccrsa_import_priv_n(size_t n,const unsigned char*b){return ccder_decode_rsa_priv_n(b,b+n);}
API int ccrsa_import_pub(ccrsa_ctx*k,size_t n,const unsigned char*b){return !ccder_decode_rsa_pub_x509(k,b,b+n)&&!ccder_decode_rsa_pub(k,b,b+n);}
API int ccrsa_import_priv(ccrsa_ctx*k,size_t n,const unsigned char*b){return !ccder_decode_rsa_priv(k,b,b+n);}
