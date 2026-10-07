/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccrng.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks,failures;
static void same(const char*n,const void*a,const void*b,size_t z){checks++;if(memcmp(a,b,z)&&failures++<12)fprintf(stderr,"%s differs\n",n);}
static void result(const char*n,int a,int b){same(n,&a,&b,sizeof(a));}
static void *sym(void*h,const char*n){void*p=dlsym(h,n);if(!p){fprintf(stderr,"%s\n",dlerror());exit(2);}return p;}
struct scripted {struct ccrng_state rng;size_t calls;int error;};
static int scripted_generate(struct ccrng_state *rng,size_t n,void*out){struct scripted*s=(void*)rng;result("uniform request",8,(int)n);uint64_t value=s->calls++?0:UINT64_MAX;memcpy(out,&value,8);return s->error;}
static struct {const void*info,*state,*entropy,*nonce,*extra;size_t entropy_size,nonce_size,extra_size,calls;unsigned char personal[64];} record;
static int callback_error;
static int mock_init(const struct ccdrbg_info*i,void*s,size_t n,const void*e,size_t l,const void*v,size_t p,const void*t){record.info=i;record.state=s;record.entropy=e;record.entropy_size=n;record.nonce=v;record.nonce_size=l;record.extra_size=p;memcpy(record.personal,t,p);record.calls++;return callback_error;}
static int mock_reseed(void*s,size_t n,const void*e,size_t z,const void*x){record.state=s;record.entropy_size=n;record.entropy=e;record.extra_size=z;record.extra=x;record.calls++;return callback_error;}
static int mock_generate(void*s,size_t n,void*out,size_t z,const void*x){record.state=s;record.extra_size=z;record.extra=x;record.entropy_size=n;record.calls++;memset(out,0x39,n);return callback_error;}
static void mock_done(void*s){record.state=s;record.calls++;}
int main(int argc,char**argv)
{
    if(argc!=2)return 2;
    void*h[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL|RTLD_FIRST),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL|RTLD_FIRST)};
    if(!h[0]||!h[1])return 2;
    typedef int(*uniform_fn)(struct ccrng_state*,uint64_t,uint64_t*);
    uniform_fn uniform[2]={sym(h[0],"ccrng_uniform"),sym(h[1],"ccrng_uniform")};if(uniform[0]==uniform[1])return 2;
    const uint64_t bounds[]={0,1,2,3,7,8,255,256,257,UINT32_MAX,UINT64_MAX/2,UINT64_MAX};
    for(size_t b=0;b<sizeof(bounds)/sizeof(*bounds);b++)for(int error=0;error<2;error++){
        struct scripted rng[2]={{{scripted_generate},0,error?-123:0},{{scripted_generate},0,error?-123:0}};
        uint64_t out[2]={0xa5,0xa5};int r[2];for(int i=0;i<2;i++)r[i]=uniform[i](&rng[i].rng,bounds[b],out+i);
        result("uniform result",r[0],r[1]);same("uniform output",out,out+1,8);same("uniform calls",&rng[0].calls,&rng[1].calls,sizeof(size_t));
    }
    unsigned char source[17];for(size_t i=0;i<17;i++)source[i]=(unsigned char)(i*7+3);
    for(size_t n=0;n<=17;n++){
        _Alignas(16) unsigned char ctx[2][64];memset(ctx,0xa5,sizeof(ctx));
        for(int i=0;i<2;i++){int(*init)(void*,size_t,const void*)=sym(h[i],"ccrng_sequence_init");result("sequence init",0,init(ctx[i],n,source));}
        same("sequence layout",ctx[0]+8,ctx[1]+8,56);
        for(int call=0;call<2;call++)for(size_t length=0;length<=64;length++){
            unsigned char out[2][80];memset(out,0x5a,sizeof(out));int r[2];
            for(int i=0;i<2;i++){struct ccrng_state*rng=(void*)ctx[i];r[i]=rng->generate(rng,length,out[i]);}
            result("sequence result",r[0],r[1]);same("sequence output",out[0],out[1],80);same("sequence state",ctx[0]+8,ctx[1]+8,56);
        }
    }
    struct ccdrbg_info info={64,mock_init,mock_reseed,mock_generate,mock_done,NULL,NULL};
    unsigned char drbg_state[64],entropy[32]={0},out[32];
    for(int fail=0;fail<2;fail++){
        callback_error=fail?-123:0;
        struct ccrng_drbg_state rng[2];unsigned char records[2][sizeof(record)];int r[2];
        memset(rng,0xa5,sizeof(rng));
        for(int i=0;i<2;i++){
            int(*init)(struct ccrng_drbg_state*,const struct ccdrbg_info*,void*,size_t,const void*)=sym(h[i],"ccrng_drbg_init");
            memset(&record,0,sizeof(record));r[i]=init(rng+i,&info,drbg_state,32,entropy);memcpy(records[i],&record,sizeof(record));
        }
        result("DRBG init result",r[0],r[1]);same("DRBG init args",records[0],records[1],sizeof(record));same("DRBG fields",(unsigned char*)rng+8,(unsigned char*)(rng+1)+8,sizeof(*rng)-8);
        if(fail)continue;
        for(int i=0;i<2;i++){
            memset(&record,0,sizeof(record));result("DRBG generate",0,rng[i].rng.generate(&rng[i].rng,32,out));memcpy(records[i],&record,sizeof(record));
        }
        same("DRBG generate args",records[0],records[1],sizeof(record));
        for(int i=0;i<2;i++){
            int(*reseed)(struct ccrng_drbg_state*,size_t,const void*,size_t,const void*)=sym(h[i],"ccrng_drbg_reseed");
            memset(&record,0,sizeof(record));result("DRBG reseed",0,reseed(rng+i,17,entropy,3,source));memcpy(records[i],&record,sizeof(record));
        }
        same("DRBG reseed args",records[0],records[1],sizeof(record));
        for(int i=0;i<2;i++){
            void(*done)(struct ccrng_drbg_state*)=sym(h[i],"ccrng_drbg_done");memset(&record,0,sizeof(record));done(rng+i);memcpy(records[i],&record,sizeof(record));
        }
        same("DRBG done args",records[0],records[1],sizeof(record));same("DRBG done fields",(unsigned char*)rng+8,(unsigned char*)(rng+1)+8,sizeof(*rng)-8);
    }
    for(int i=0;i<2;i++){
        struct ccrng_state*(*get)(int*)=sym(h[i],"ccrng");int error=77;struct ccrng_state*rng=get(&error);result("system error",0,error);if(!rng)return 2;
        unsigned char bytes[4112],again[4112];memset(bytes,0xa5,sizeof(bytes));memset(again,0xa5,sizeof(again));
        result("system empty",0,rng->generate(rng,0,NULL));result("system bytes",0,rng->generate(rng,4096,bytes));result("system again",0,rng->generate(rng,4096,again));
        checks++;if(!memcmp(bytes,again,4096)){fprintf(stderr,"repeated system output\n");failures++;}
        unsigned char guard[16];memset(guard,0xa5,16);same("system guard",guard,bytes+4096,16);same("system second guard",guard,again+4096,16);
        struct ccrng_state*(*trng)(int*)=sym(h[i],"ccrng_trng");error=0;checks++;if(trng(&error)!=NULL)failures++;result("TRNG unavailable",-173,error);
    }
    printf("RNG ABI: %u checks, %u failures\n",checks,failures);return failures?1:0;
}
