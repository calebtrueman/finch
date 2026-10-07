/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#define OPENSSL_SUPPRESS_DEPRECATED
#include "legacy_ciphers.h"
#include <openssl/des.h>
#include <openssl/crypto.h>

#include <openssl/rc2.h>
#include <openssl/rc4.h>
#include <openssl/cast.h>
#include <openssl/blowfish.h>
#include <string.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdint.h>
#define EXPORT __attribute__((visibility("default")))
/* The host stores each DES round in two words, followed by the reversed
 * round order. Translate those words at the backend boundary. */
static void des_store(unsigned *out,const DES_key_schedule *s,int reverse)
{
    const unsigned *w=(const unsigned*)s;
    for(unsigned r=0;r<16;r++)for(unsigned j=0;j<2;j++){
        unsigned v=0,src=w[2*(reverse?15-r:r)+j];
        for(unsigned b=0;b<32;b++)if((b&7)<6)v|=((src>>((j?35-b:31-b)&31))&1)<<b;
        out[2*r+j]=v;
    }
}
static void des_load(DES_key_schedule *s,const unsigned *in)
{
    unsigned *w=(unsigned*)s;
    for(unsigned r=0;r<16;r++)for(unsigned j=0;j<2;j++){
        unsigned v=0;for(unsigned b=0;b<32;b++)if((b&7)<6)v|=((in[2*r+j]>>b)&1)<<((j?35-b:31-b)&31);
        w[2*r+j]=v;
    }
}
static int des_init(const struct ccmode_ecb*m,void*c,size_t n,const void*k){(void)m;if(n!=8)return -1;DES_key_schedule s;DES_set_key_unchecked((const_DES_cblock*)k,&s);des_store(c,&s,0);des_store((unsigned*)c+32,&s,1);OPENSSL_cleanse(&s,sizeof s);return 0;}
static int des3_init(const struct ccmode_ecb*m,void*c,size_t n,const void*k){(void)m;const unsigned char*p=k;if(n!=24)return -1;DES_key_schedule s;for(int i=0;i<3;i++){DES_set_key_unchecked((const_DES_cblock*)(p+8*i),&s);des_store((unsigned*)c+32*i,&s,i==1);des_store((unsigned*)c+96+32*(2-i),&s,i!=1);}OPENSSL_cleanse(&s,sizeof s);return !memcmp(p,p+8,8)||!memcmp(p,p+16,8)||!memcmp(p+8,p+16,8)?-1:0;}
static int rc2_init(const struct ccmode_ecb*m,void*c,size_t n,const void*k){(void)m;if(!n||n>128)return -7;RC2_set_key(c,(int)n,k,(int)n*8);return 0;}
static int cast_init(const struct ccmode_ecb*m,void*c,size_t n,const void*k){(void)m;CAST_set_key(c,n>16?16:(int)n,k);return 0;}
static int bf_init(const struct ccmode_ecb*m,void*c,size_t n,const void*k){(void)m;BF_KEY tmp;BF_set_key(&tmp,!n||n>72?72:(int)n,k);memcpy(c,tmp.S,sizeof tmp.S);memcpy((unsigned char*)c+sizeof tmp.S,tmp.P,sizeof tmp.P);OPENSSL_cleanse(&tmp,sizeof tmp);return 0;}
#define BLOCKS(NAME,TYPE,CALL) \
static int NAME##_crypt(const void*c,size_t n,const void*input,void*output,int dir){const unsigned char*in=input;unsigned char*out=output;while(n--){CALL;in+=8;out+=8;}return 0;} \
static int NAME##_enc(const void*c,size_t n,const void*i,void*o){return NAME##_crypt(c,n,i,o,1);} \
static int NAME##_dec(const void*c,size_t n,const void*i,void*o){return NAME##_crypt(c,n,i,o,0);}
static int des_crypt(const void*c,size_t n,const void*input,void*output,int dir){DES_key_schedule s;des_load(&s,c);const unsigned char*in=input;unsigned char*out=output;while(n--){DES_ecb_encrypt((const_DES_cblock*)in,(DES_cblock*)out,&s,dir);in+=8;out+=8;}OPENSSL_cleanse(&s,sizeof s);return 0;}
static int des_enc(const void*c,size_t n,const void*i,void*o){return des_crypt(c,n,i,o,1);}
static int des_dec(const void*c,size_t n,const void*i,void*o){return des_crypt(c,n,i,o,0);}
static int des3_crypt(const void*c,size_t n,const void*input,void*output,int dir){DES_key_schedule s[3];unsigned middle[32];des_load(&s[0],c);for(int r=0;r<16;r++){middle[2*r]=((const unsigned*)c)[32+2*(15-r)];middle[2*r+1]=((const unsigned*)c)[33+2*(15-r)];}des_load(&s[1],middle);des_load(&s[2],(const unsigned*)c+64);const unsigned char*in=input;unsigned char*out=output;while(n--){DES_ecb3_encrypt((const_DES_cblock*)in,(DES_cblock*)out,&s[0],&s[1],&s[2],dir);in+=8;out+=8;}OPENSSL_cleanse(s,sizeof s);OPENSSL_cleanse(middle,sizeof middle);return 0;}
static int des3_enc(const void*c,size_t n,const void*i,void*o){return des3_crypt(c,n,i,o,1);}
static int des3_dec(const void*c,size_t n,const void*i,void*o){return des3_crypt(c,n,i,o,0);}
BLOCKS(rc2,RC2_KEY,RC2_ecb_encrypt(in,out,(RC2_KEY*)c,dir))
BLOCKS(cast,CAST_KEY,CAST_ecb_encrypt(in,out,(CAST_KEY*)c,dir))
static int bf_crypt(const void*c,size_t n,const void*input,void*output,int dir){BF_KEY tmp;memcpy(tmp.S,c,sizeof tmp.S);memcpy(tmp.P,(const unsigned char*)c+sizeof tmp.S,sizeof tmp.P);const unsigned char*in=input;unsigned char*out=output;while(n--){BF_ecb_encrypt(in,out,&tmp,dir);in+=8;out+=8;}OPENSSL_cleanse(&tmp,sizeof tmp);return 0;}
static int bf_enc(const void*c,size_t n,const void*i,void*o){return bf_crypt(c,n,i,o,1);}
static int bf_dec(const void*c,size_t n,const void*i,void*o){return bf_crypt(c,n,i,o,0);}
extern void ccmode_factory_cbc_encrypt(struct ccmode_cbc*,const struct ccmode_ecb*);
extern void ccmode_factory_cbc_decrypt(struct ccmode_cbc*,const struct ccmode_ecb*);
extern void ccmode_factory_ctr_crypt(struct ccmode_ctr*,const struct ccmode_ecb*);
extern void ccmode_factory_cfb_encrypt(struct ccmode_stream*,const struct ccmode_ecb*);
extern void ccmode_factory_cfb_decrypt(struct ccmode_stream*,const struct ccmode_ecb*);
extern void ccmode_factory_cfb8_encrypt(struct ccmode_stream*,const struct ccmode_ecb*);
extern void ccmode_factory_cfb8_decrypt(struct ccmode_stream*,const struct ccmode_ecb*);
extern void ccmode_factory_ofb_crypt(struct ccmode_stream*,const struct ccmode_ecb*);
#define FAMILY(P,N,S) \
static const struct ccmode_ecb P##_ee={S,8,N##_init,N##_enc},P##_ed={S,8,N##_init,N##_dec}; \
EXPORT const struct ccmode_ecb*P##_ecb_encrypt_mode(void){return &P##_ee;} \
EXPORT const struct ccmode_ecb*P##_ecb_decrypt_mode(void){return &P##_ed;} \
static struct ccmode_cbc P##_ce,P##_cd;static struct ccmode_ctr P##_ctr; \
static struct ccmode_stream P##_fe,P##_fd,P##_f8e,P##_f8d,P##_ofb; \
static pthread_once_t P##_once=PTHREAD_ONCE_INIT; \
static void P##_setup(void){ccmode_factory_cbc_encrypt(&P##_ce,&P##_ee);ccmode_factory_cbc_decrypt(&P##_cd,&P##_ed);ccmode_factory_ctr_crypt(&P##_ctr,&P##_ee);ccmode_factory_cfb_encrypt(&P##_fe,&P##_ee);ccmode_factory_cfb_decrypt(&P##_fd,&P##_ee);ccmode_factory_cfb8_encrypt(&P##_f8e,&P##_ee);ccmode_factory_cfb8_decrypt(&P##_f8d,&P##_ee);ccmode_factory_ofb_crypt(&P##_ofb,&P##_ee);} \
EXPORT const struct ccmode_cbc*P##_cbc_encrypt_mode(void){pthread_once(&P##_once,P##_setup);return &P##_ce;} \
EXPORT const struct ccmode_cbc*P##_cbc_decrypt_mode(void){pthread_once(&P##_once,P##_setup);return &P##_cd;} \
EXPORT const struct ccmode_ctr*P##_ctr_crypt_mode(void){pthread_once(&P##_once,P##_setup);return &P##_ctr;} \
EXPORT const struct ccmode_stream*P##_cfb_encrypt_mode(void){pthread_once(&P##_once,P##_setup);return &P##_fe;} \
EXPORT const struct ccmode_stream*P##_cfb_decrypt_mode(void){pthread_once(&P##_once,P##_setup);return &P##_fd;} \
EXPORT const struct ccmode_stream*P##_cfb8_encrypt_mode(void){pthread_once(&P##_once,P##_setup);return &P##_f8e;} \
EXPORT const struct ccmode_stream*P##_cfb8_decrypt_mode(void){pthread_once(&P##_once,P##_setup);return &P##_f8d;} \
EXPORT const struct ccmode_stream*P##_ofb_crypt_mode(void){pthread_once(&P##_once,P##_setup);return &P##_ofb;}
FAMILY(ccdes,des,256)
FAMILY(ccdes3,des3,768)
FAMILY(ccrc2,rc2,256)
FAMILY(cccast,cast,132)
FAMILY(ccblowfish,bf,4168)
EXPORT const struct ccmode_ecb ccdes3_ltc_ecb_encrypt_mode={768,8,des3_init,des3_enc};
EXPORT const struct ccmode_ecb ccdes3_ltc_ecb_decrypt_mode={768,8,des3_init,des3_dec};
static void rc4_init(void*c,size_t n,const void*k){RC4_set_key(c,n?(int)n:256,k);}
static void rc4_crypt(void*c,size_t n,const void*i,void*o){RC4(c,n,i,o);}
EXPORT const struct ccrc4_info ccrc4_eay={sizeof(RC4_KEY),rc4_init,rc4_crypt};
EXPORT const struct ccrc4_info*ccrc4(void){return &ccrc4_eay;}
EXPORT void ccdes_key_set_odd_parity(void*k,size_t n){unsigned char*p=k;while(n--){unsigned char x=*p&254;*p++=x|((__builtin_popcount((unsigned)x)&1)^1);}}
EXPORT int ccdes_key_is_weak(const void*k,size_t n){return n!=8||DES_is_weak_key((const_DES_cblock*)k)?-1:0;}
EXPORT unsigned long ccdes_cbc_cksum(const void*in,void*out,size_t n,const void*key,size_t kn,const void*iv){DES_key_schedule s;if(kn!=8){unsigned char noise[8];arc4random_buf(noise,sizeof noise);if(out)memcpy(out,noise,8);unsigned long r=((unsigned long)noise[4]<<24)|((unsigned long)noise[5]<<16)|((unsigned long)noise[6]<<8)|noise[7];OPENSSL_cleanse(noise,sizeof noise);return r;}if(!n){if(out)memset(out,0,8);return 0;}DES_set_key_unchecked((const_DES_cblock*)key,&s);unsigned long r=DES_cbc_cksum(in,out,(long)n,&s,(const_DES_cblock*)iv);OPENSSL_cleanse(&s,sizeof s);return r;}
