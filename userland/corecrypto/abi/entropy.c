/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "ccdigest.h"
#include "ccrng.h"
#include <os/lock.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))
struct entropy_info {int(*seed)(void*,size_t,void*);int(*add)(void*,unsigned,size_t,const void*,bool*);int(*reset)(void*);};
struct entropy {const struct entropy_info *info;};
struct entropy_digest {const struct entropy_info *info;const struct ccdigest_info *di;unsigned char digest[360];unsigned needed,available;};
struct entropy_rng {const struct entropy_info *info;struct ccrng_state *rng;};
struct entropy_list {const struct entropy_info *info;void **sources;size_t count;};
struct entropy_lock {const struct entropy_info *info;void *source;os_unfair_lock_t lock;};
static void wipe(void*p,size_t n){volatile unsigned char*b=p;while(n--)*b++=0;}
EXPORT int ccentropy_get_seed(void*p,size_t n,void*out){return ((struct entropy*)p)->info->seed(p,n,out);}
EXPORT int ccentropy_add_entropy(void*p,unsigned bits,size_t n,const void*in,bool*ready){if(ready)*ready=false;const struct entropy_info*i=((struct entropy*)p)->info;return i->add?i->add(p,bits,n,in,ready):-173;}
EXPORT int ccentropy_reset(void*p){const struct entropy_info*i=((struct entropy*)p)->info;return i->reset?i->reset(p):-173;}
static int digest_seed(void*p,size_t n,void*out){struct entropy_digest*c=p;if(n>c->di->output_size)return -5;if(c->available<c->needed)return -10;unsigned char digest[c->di->output_size];c->available=0;c->di->final(c->di,c->digest,digest);ccdigest_init(c->di,c->digest);memcpy(out,digest,n);wipe(digest,sizeof(digest));return 0;}
static int digest_add(void*p,unsigned bits,size_t n,const void*in,bool*ready){struct entropy_digest*c=p;unsigned v=c->available+bits;c->available=v<c->available?UINT32_MAX:v;if(ready)*ready=c->available>=c->needed;ccdigest_update(c->di,c->digest,n,in);return 0;}
static int digest_reset(void*p){((struct entropy_digest*)p)->available=0;return 0;}
static const struct entropy_info digest_info={digest_seed,digest_add,digest_reset};
EXPORT int ccentropy_digest_init(void*p,const struct ccdigest_info*di,unsigned bits){struct entropy_digest*c=p;c->info=&digest_info;c->di=di;c->needed=bits;c->available=0;ccdigest_init(di,c->digest);return 0;}
static int rng_seed(void*p,size_t n,void*out){struct ccrng_state*r=((struct entropy_rng*)p)->rng;return r->generate(r,n,out);}
static const struct entropy_info rng_info={rng_seed,NULL,NULL};
EXPORT int ccentropy_rng_init(void*p,struct ccrng_state*rng){struct entropy_rng*c=p;c->info=&rng_info;c->rng=rng;return 0;}
static int list_seed(void*p,size_t n,void*out){struct entropy_list*c=p;int r=-1;for(size_t i=0;i<c->count;i++){r=ccentropy_get_seed(c->sources[i],n,out);if(r!=-10)break;}if(r)wipe(out,n);return r;}
static const struct entropy_info list_info={list_seed,NULL,NULL};
EXPORT int ccentropy_list_init(void*p,size_t n,void**sources){struct entropy_list*c=p;c->info=&list_info;c->sources=sources;c->count=n;return 0;}
static int lock_seed(void*p,size_t n,void*out){struct entropy_lock*c=p;os_unfair_lock_lock(c->lock);int r=ccentropy_get_seed(c->source,n,out);os_unfair_lock_unlock(c->lock);return r;}
static int lock_add(void*p,unsigned bits,size_t n,const void*in,bool*ready){struct entropy_lock*c=p;os_unfair_lock_lock(c->lock);int r=ccentropy_add_entropy(c->source,bits,n,in,ready);os_unfair_lock_unlock(c->lock);return r;}
static int lock_reset(void*p){struct entropy_lock*c=p;os_unfair_lock_lock(c->lock);int r=ccentropy_reset(c->source);os_unfair_lock_unlock(c->lock);return r;}
static const struct entropy_info lock_info={lock_seed,lock_add,lock_reset};
EXPORT int ccentropy_lock_init(void*p,void*source,os_unfair_lock_t lock){struct entropy_lock*c=p;c->info=&lock_info;c->source=source;c->lock=lock;return 0;}
