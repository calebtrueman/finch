/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Independent Ed25519 VRF draft-03 arithmetic. Field and secret scalar loops
 * have fixed bounds; point multiplication selects with masks. */
#include "ccvrf.h"
#include <openssl/crypto.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
#define MASK51 UINT64_C(2251799813685247)
typedef struct {uint64_t v[5];} fe;
typedef struct {fe x,y,z,t;} point;
static const fe zero={{0}},one={{1}};
static fe ed_d,sqrt_m1;
static point base;
static pthread_once_t once=PTHREAD_ONCE_INIT;
static void carry(fe*a){for(int k=0;k<3;k++){for(int j=0;j<4;j++){a->v[j+1]+=a->v[j]>>51;a->v[j]&=MASK51;}uint64_t c=a->v[4]>>51;a->v[4]&=MASK51;a->v[0]+=19*c;}}
static void add(fe*r,const fe*a,const fe*b){for(int j=0;j<5;j++)r->v[j]=a->v[j]+b->v[j];carry(r);}
static void sub(fe*r,const fe*a,const fe*b){for(int j=0;j<5;j++)r->v[j]=a->v[j]+2*(MASK51-(j==0?18:0))-b->v[j];carry(r);}
static void mul(fe*r,const fe*a,const fe*b){__uint128_t t[5]={0};for(int i=0;i<5;i++)for(int j=0;j<5;j++)t[(i+j)%5]+=(__uint128_t)a->v[i]*b->v[j]*(i+j>=5?19:1);for(int i=0;i<4;i++){t[i+1]+=t[i]>>51;t[i]&=MASK51;}t[0]+=19*(t[4]>>51);t[4]&=MASK51;for(int i=0;i<5;i++)r->v[i]=(uint64_t)t[i];carry(r);}
static void sq(fe*r,const fe*a){mul(r,a,a);}
static void select_fe(fe*r,const fe*a,const fe*b,uint64_t bit){uint64_t mask=0-bit;for(int j=0;j<5;j++)r->v[j]=(a->v[j]&~mask)|(b->v[j]&mask);}
static void pow_fe(fe*r,const fe*a,const unsigned char e[32],int bits){fe v=one;for(int j=bits-1;j>=0;j--){sq(&v,&v);if((e[j/8]>>(j%8))&1)mul(&v,&v,a);}*r=v;}
static void inverse(fe*r,const fe*a){unsigned char e[32];memset(e,255,32);e[0]=235;e[31]=127;pow_fe(r,a,e,255);}
static void read_fe(fe*r,const unsigned char*s){*r=zero;for(int j=0;j<255;j++)r->v[j/51]|=(uint64_t)((s[j/8]>>(j%8))&1)<<(j%51);}
static void write_fe(unsigned char*s,const fe*a){fe r=*a;carry(&r);uint64_t v[5],borrow=0;for(int j=0;j<5;j++){uint64_t p=MASK51-(j==0?18:0),q=p+borrow;v[j]=(r.v[j]-q)&MASK51;borrow=r.v[j]<q;}uint64_t mask=0-(1-borrow);for(int j=0;j<5;j++)r.v[j]=(r.v[j]&~mask)|(v[j]&mask);memset(s,0,32);for(int j=0;j<255;j++)s[j/8]|=((r.v[j/51]>>(j%51))&1)<<(j%8);}
static int equal(const fe*a,const fe*b){unsigned char x[32],y[32];write_fe(x,a);write_fe(y,b);return CRYPTO_memcmp(x,y,32)==0;}
static int parity(const fe*a){unsigned char b[32];write_fe(b,a);return b[0]&1;}
static int root(fe*r,const fe*a){unsigned char e[32];memset(e,255,32);e[0]=254;e[31]=15;pow_fe(r,a,e,252);fe t;sq(&t,r);if(!equal(&t,a))mul(r,r,&sqrt_m1);sq(&t,r);return equal(&t,a);}
static void identity(point*p){p->x=zero;p->y=one;p->z=one;p->t=zero;}
static void plus(point*r,const point*p,const point*q){fe a,b,c,d,e,f,g,h,u,v;sub(&u,&p->y,&p->x);sub(&v,&q->y,&q->x);mul(&a,&u,&v);add(&u,&p->y,&p->x);add(&v,&q->y,&q->x);mul(&b,&u,&v);mul(&c,&p->t,&q->t);mul(&c,&c,&ed_d);add(&c,&c,&c);mul(&d,&p->z,&q->z);add(&d,&d,&d);sub(&e,&b,&a);sub(&f,&d,&c);add(&g,&d,&c);add(&h,&b,&a);point o;mul(&o.x,&e,&f);mul(&o.y,&g,&h);mul(&o.t,&e,&h);mul(&o.z,&f,&g);*r=o;}
static void negate(point*p){sub(&p->x,&zero,&p->x);sub(&p->t,&zero,&p->t);}
static void select_point(point*r,const point*a,const point*b,uint64_t bit){select_fe(&r->x,&a->x,&b->x,bit);select_fe(&r->y,&a->y,&b->y,bit);select_fe(&r->z,&a->z,&b->z,bit);select_fe(&r->t,&a->t,&b->t,bit);}
static void times(point*r,const point*p,const unsigned char*s){point a,b;identity(&a);for(int j=255;j>=0;j--){plus(&a,&a,&a);plus(&b,&a,p);select_point(&a,&a,&b,(s[j/8]>>(j%8))&1);}*r=a;OPENSSL_cleanse(&a,sizeof(a));OPENSSL_cleanse(&b,sizeof(b));}
static void encode(unsigned char*out,const point*p){fe inv,x,y;inverse(&inv,&p->z);mul(&x,&p->x,&inv);mul(&y,&p->y,&inv);write_fe(out,&y);out[31]|=parity(&x)<<7;}
static int decode(point*p,const unsigned char*in){fe y2,u,v,inv,x2;read_fe(&p->y,in);sq(&y2,&p->y);sub(&u,&y2,&one);mul(&v,&ed_d,&y2);add(&v,&v,&one);inverse(&inv,&v);mul(&x2,&u,&inv);if(!root(&p->x,&x2))return -87;if(parity(&p->x)!=(in[31]>>7))sub(&p->x,&zero,&p->x);p->z=one;mul(&p->t,&p->x,&p->y);return 0;}
static void init_math(void){fe a={{121665}},b={{121666}},inv;inverse(&inv,&b);mul(&ed_d,&a,&inv);sub(&ed_d,&zero,&ed_d);unsigned char e[32];memset(e,255,32);e[0]=251;e[31]=31;fe two={{2}};pow_fe(&sqrt_m1,&two,e,253);unsigned char enc[32];memset(enc,0x66,32);enc[0]=0x58;decode(&base,enc);}
static void cofactor(point*p){for(int j=0;j<3;j++)plus(p,p,p);}
static void uniform(point*p,const unsigned char*in){fe r,u,v,g,a={{486662}},inv,x2;read_fe(&r,in);sq(&u,&r);add(&u,&u,&u);add(&u,&u,&one);inverse(&inv,&u);mul(&u,&a,&inv);sub(&u,&zero,&u);sq(&x2,&u);mul(&g,&x2,&u);mul(&v,&a,&x2);add(&g,&g,&v);add(&g,&g,&u);if(!root(&v,&g)){sub(&u,&zero,&u);sub(&u,&u,&a);}sub(&v,&u,&one);add(&u,&u,&one);inverse(&inv,&u);mul(&v,&v,&inv);unsigned char enc[32];write_fe(enc,&v);decode(p,enc);cofactor(p);}
static const uint64_t order[4]={UINT64_C(0x5812631a5cf5d3ed),UINT64_C(0x14def9dea2f79cd6),0,UINT64_C(0x1000000000000000)};
static void reduce(unsigned char*out,const unsigned char*in,size_t n){uint64_t r[4]={0};for(size_t b=8*n;b>0;b--){uint64_t carrybit=(in[(b-1)/8]>>((b-1)%8))&1;for(int j=0;j<4;j++){uint64_t t=r[j]>>63;r[j]=(r[j]<<1)|carrybit;carrybit=t;}uint64_t subbed[4],borrow=0;for(int j=0;j<4;j++){__uint128_t q=(__uint128_t)order[j]+borrow;subbed[j]=r[j]-(uint64_t)q;borrow=(__uint128_t)r[j]<q;}uint64_t mask=0-(1-borrow);for(int j=0;j<4;j++)r[j]=(r[j]&~mask)|(subbed[j]&mask);}for(int j=0;j<32;j++)out[j]=r[j/8]>>(8*(j%8));OPENSSL_cleanse(r,sizeof(r));}
static void muladd(unsigned char*out,const unsigned char*a,const unsigned char*b,const unsigned char*c){uint32_t t[64]={0};unsigned char bytes[64];for(int i=0;i<32;i++){t[i]+=c[i];for(int j=0;j<32;j++)t[i+j]+=(unsigned)a[i]*b[j];}for(int i=0;i<63;i++){t[i+1]+=t[i]>>8;bytes[i]=t[i];}bytes[63]=t[63];reduce(out,bytes,64);OPENSSL_cleanse(t,sizeof(t));OPENSSL_cleanse(bytes,sizeof(bytes));}
static void digest_parts(const struct ccvrf_info*i,const void*a,size_t an,const void*b,size_t bn,const void*c,size_t cn,void*out){size_t sz=ccdigest_di_size(i->di);unsigned char ctx[sz];ccdigest_init(i->di,ctx);ccdigest_update(i->di,ctx,an,a);ccdigest_update(i->di,ctx,bn,b);ccdigest_update(i->di,ctx,cn,c);i->di->final(i->di,ctx,out);OPENSSL_cleanse(ctx,sz);}
static void scalar(const struct ccvrf_info*i,const void*sk,unsigned char ex[64]){ccdigest(i->di,32,sk,ex);ex[0]&=248;ex[31]&=127;ex[31]|=64;}
static int public_key(const struct ccvrf_info*i,const void*sk,void*out){pthread_once(&once,init_math);unsigned char ex[64];point p;scalar(i,sk,ex);times(&p,&base,ex);encode(out,&p);OPENSSL_cleanse(ex,sizeof(ex));OPENSSL_cleanse(&p,sizeof(p));return 0;}
static void hash_curve(const struct ccvrf_info*i,const point*y,const void*m,size_t n,point*h){unsigned char prefix[34]={4,1},hashed[64];encode(prefix+2,y);digest_parts(i,prefix,34,m,n,NULL,0,hashed);hashed[31]&=127;uniform(h,hashed);OPENSSL_cleanse(hashed,sizeof(hashed));}
static void challenge(const struct ccvrf_info*i,const point*h,const point*g,const point*u,const point*v,unsigned char*c){unsigned char b[130]={4,2},out[64];encode(b+2,h);encode(b+34,g);encode(b+66,u);encode(b+98,v);ccdigest(i->di,sizeof(b),b,out);memcpy(c,out,16);memset(c+16,0,16);OPENSSL_cleanse(out,sizeof(out));}
static int prove(const struct ccvrf_info*i,const void*sk,const void*m,size_t n,void*out){pthread_once(&once,init_math);unsigned char ex[64],hb[32],kh[64],k[32],c[32],s[32];point y,h,g,u,v;scalar(i,sk,ex);times(&y,&base,ex);hash_curve(i,&y,m,n,&h);times(&g,&h,ex);encode(hb,&h);digest_parts(i,ex+32,32,hb,32,NULL,0,kh);reduce(k,kh,64);times(&u,&base,k);times(&v,&h,k);challenge(i,&h,&g,&u,&v,c);muladd(s,c,ex,k);encode(out,&g);memcpy((unsigned char*)out+32,c,16);memcpy((unsigned char*)out+48,s,32);OPENSSL_cleanse(ex,sizeof(ex));OPENSSL_cleanse(kh,sizeof(kh));OPENSSL_cleanse(k,sizeof(k));OPENSSL_cleanse(&g,sizeof(g));OPENSSL_cleanse(&u,sizeof(u));OPENSSL_cleanse(&v,sizeof(v));return 0;}
static int verify(const struct ccvrf_info*i,const void*pk,const void*m,size_t n,const void*proof){pthread_once(&once,init_math);point y,h,g,u,v,t;int rc=decode(&y,pk);if(rc)return rc;t=y;cofactor(&t);if(equal(&t.x,&zero)&&equal(&t.y,&t.z))return -88;rc=decode(&g,proof);if(rc)return rc;unsigned char c[32]={0},s[32],check[32];memcpy(c,(const unsigned char*)proof+32,16);reduce(s,(const unsigned char*)proof+48,32);hash_curve(i,&y,m,n,&h);times(&u,&base,s);times(&t,&y,c);negate(&t);plus(&u,&u,&t);times(&v,&h,s);times(&t,&g,c);negate(&t);plus(&v,&v,&t);challenge(i,&h,&g,&u,&v,check);return CRYPTO_memcmp(c,check,16)?-89:0;}
static int proof_hash(const struct ccvrf_info*i,const void*proof,void*out){pthread_once(&once,init_math);point p;int rc=decode(&p,proof);if(rc)return rc;cofactor(&p);unsigned char b[34]={4,3};encode(b+2,&p);ccdigest(i->di,sizeof(b),b,out);return 0;}
EXPORT void ccvrf_factory_irtfdraft03(struct ccvrf_info*i,const struct ccdigest_info*di){if(di->output_size!=64)return;*i=(struct ccvrf_info){32,32,80,64,32,di,NULL,public_key,prove,verify,proof_hash};}
EXPORT void ccvrf_factory_irtfdraft03_default(struct ccvrf_info*i){ccvrf_factory_irtfdraft03(i,ccsha512_di());}
EXPORT size_t ccvrf_sizeof_public_key(const struct ccvrf_info*i){return i->public_key_size;}
EXPORT size_t ccvrf_sizeof_secret_key(const struct ccvrf_info*i){return i->secret_key_size;}
EXPORT size_t ccvrf_sizeof_proof(const struct ccvrf_info*i){return i->proof_size;}
EXPORT size_t ccvrf_sizeof_hash(const struct ccvrf_info*i){return i->hash_size;}
EXPORT int ccvrf_derive_public_key(const struct ccvrf_info*i,size_t sn,const void*s,size_t pn,void*p){return sn==i->secret_key_size&&pn==i->public_key_size?i->derive_public_key(i,s,p):-7;}
EXPORT int ccvrf_prove(const struct ccvrf_info*i,size_t sn,const void*s,size_t n,const void*m,size_t pn,void*p){return sn==i->secret_key_size&&pn==i->proof_size?i->prove(i,s,m,n,p):-7;}
EXPORT int ccvrf_verify(const struct ccvrf_info*i,size_t kn,const void*k,size_t n,const void*m,size_t pn,const void*p){return kn==i->public_key_size&&pn==i->proof_size?i->verify(i,k,m,n,p):-7;}
EXPORT int ccvrf_proof_to_hash(const struct ccvrf_info*i,size_t pn,const void*p,size_t hn,void*h){return pn==i->proof_size&&hn==i->hash_size?i->proof_to_hash(i,p,h):-7;}
