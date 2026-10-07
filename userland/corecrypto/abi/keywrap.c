/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccmode.h"
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
static const unsigned char default_iv[8]={0xa6,0xa6,0xa6,0xa6,0xa6,0xa6,0xa6,0xa6};
static void wipe(void*p,size_t n){volatile unsigned char*b=p;while(n--)*b++=0;}
EXPORT size_t ccwrap_wrapped_size(size_t n){return n+8;}
EXPORT size_t ccwrap_unwrapped_size(size_t n){return n<8?0:n-8;}
static int valid(const struct ccmode_ecb*m,size_t n){return m->block_size==16&&n>=16&&n<=65536&&!(n&7);}
static void counter(unsigned char*a,uint64_t t){for(int i=7;i>=0;i--){a[i]^=(unsigned char)t;t>>=8;}}
EXPORT int ccwrap_auth_encrypt_withiv(const struct ccmode_ecb*m,const void*c,size_t n,const void*in,size_t*on,void*out,const void*iv)
{
    *on=n+8;if(!valid(m,n)){*on=0;return -7;}
    unsigned char block[16],*o=out;memcpy(block,iv,8);memmove(o+8,in,n);size_t count=n/8;
    for(size_t j=0;j<6;j++)for(size_t i=1;i<=count;i++){memcpy(block+8,o+8*i,8);int r=m->ecb(c,1,block,block);if(r){wipe(block,16);return r;}counter(block,count*j+i);memcpy(o+8*i,block+8,8);}
    memcpy(o,block,8);wipe(block,16);return 0;
}
EXPORT int ccwrap_auth_encrypt(const struct ccmode_ecb*m,const void*c,size_t n,const void*i,size_t*on,void*o){return ccwrap_auth_encrypt_withiv(m,c,n,i,on,o,default_iv);}
EXPORT int ccwrap_auth_decrypt_withiv(const struct ccmode_ecb*m,const void*c,size_t n,const void*in,size_t*on,void*out,const void*iv)
{
    size_t plain=ccwrap_unwrapped_size(n);*on=plain;
    if(!valid(m,plain)){*on=0;wipe(out,plain);return -7;}
    unsigned char block[16],*o=out;memcpy(block,in,8);memmove(o,(const unsigned char*)in+8,plain);size_t count=plain/8;
    for(size_t j=6;j-->0;)for(size_t i=count;i;i--){counter(block,count*j+i);memcpy(block+8,o+8*(i-1),8);int r=m->ecb(c,1,block,block);if(r){wipe(block,16);wipe(out,plain);*on=0;return r;}memcpy(o+8*(i-1),block+8,8);}
    unsigned bad=0;for(size_t i=0;i<8;i++)bad|=block[i]^((const unsigned char*)iv)[i];wipe(block,16);
    if(bad){*on=0;wipe(out,plain);return -2;}return 0;
}
EXPORT int ccwrap_auth_decrypt(const struct ccmode_ecb*m,const void*c,size_t n,const void*i,size_t*on,void*o){return ccwrap_auth_decrypt_withiv(m,c,n,i,on,o,default_iv);}
