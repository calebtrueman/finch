/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccmode.h"
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
struct lr_ctx;
struct lr_info {int(*prf)(const struct lr_ctx*,void*,const void*);};
struct lr_ctx {const struct lr_info*info;size_t bits,rounds;const struct ccmode_ecb*ecb;const void*key;};
static int prf(const struct lr_ctx*c,void*out,const void*in){return c->ecb->ecb(c->key,1,in,out);}
static const struct lr_info aes_info={prf};
static void wipe(void*p,size_t n){volatile unsigned char*b=p;while(n--)*b++=0;}
EXPORT int cclr_aes_init(void*p,const struct ccmode_ecb*e,const void*key,size_t bits,size_t rounds){struct lr_ctx*c=p;c->ecb=e;c->key=key;if(bits<1||bits>128||(bits&7)||rounds<4||rounds>10)return -7;c->info=&aes_info;c->bits=bits;c->rounds=rounds;return 0;}
EXPORT size_t cclr_block_nbytes(const void*p){return (((const struct lr_ctx*)p)->bits+7)/8;}
static int permute(const struct lr_ctx*c,size_t n,void*output,const void*input,int dec){if(c->rounds<4||c->rounds>10)return -7;if(n!=(c->bits+7)/8){wipe(output,n);return -7;}unsigned char halves[2][8]={{0}},block[16]={0},pad[16];size_t half=c->bits/2,bytes=(half+7)/8;const unsigned char*in=input;unsigned char*out=output;for(size_t i=0;i<c->bits;i++)halves[i/half][(i%half)/8]|=((in[i/8]>>(7-i%8))&1)<<(7-(i%half)%8);block[0]=c->bits;block[1]=c->rounds;int result=0;for(size_t r=0;r<c->rounds;r++){size_t round=dec?c->rounds-1-r:r,target=round&1;block[2]=round;memcpy(block+3,halves[1-target],bytes);result=c->info->prf(c,pad,block);if(result)break;for(size_t i=0;i<bytes;i++)halves[target][i]^=pad[i];if(half%8)halves[target][bytes-1]&=(unsigned char)(0xff<<(8-half%8));}memset(out,0,n);if(!result)for(size_t i=0;i<c->bits;i++)out[i/8]|=((halves[i/half][(i%half)/8]>>(7-(i%half)%8))&1)<<(7-i%8);wipe(halves,sizeof(halves));wipe(block,16);wipe(pad,16);return result;}
EXPORT int cclr_encrypt_block(const void*c,size_t n,void*out,const void*in){return permute(c,n,out,in,0);}
EXPORT int cclr_decrypt_block(const void*c,size_t n,void*out,const void*in){return permute(c,n,out,in,1);}
