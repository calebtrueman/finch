/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "he-symbol-owner.h"
static unsigned checks;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"line %d: %s\n",__LINE__,#x);exit(1);}}while(0)
int main(int argc,char**argv){
    CHECK(argc==2||argc==3);void*host=dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),*local=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if(!local)fprintf(stderr,"%s\n",dlerror());CHECK(host&&local);finch_test_set_local(local,argv[1]);
    CHECK(!memcmp(dlsym(host,"CCMLDSA_FAULT_CANARY"),dlsym(local,"CCMLDSA_FAULT_CANARY"),16));
    void**ht=dlsym(host,"fipspost_trace_vtable"),**lt=dlsym(local,"fipspost_trace_vtable");CHECK(!*ht&&!*lt);
    int(*h)(uint32_t,const void*)=dlsym(host,"fipspost_post"),(*f)(uint32_t,const void*)=dlsym(local,"fipspost_post");
    const unsigned modes[]={4,64,80,320,336,84};
    for(unsigned i=0;i<sizeof modes/sizeof modes[0];i++){int a=h(modes[i],NULL),b=f(modes[i],NULL);if(a!=b)fprintf(stderr,"mode %u host %d local %d\n",modes[i],a,b);CHECK(a==b);}
    /* The host cannot accept a null image without skip-integrity. Finch can
     * find its own image, and must reject another library's image header. */
    int expected=argc==3?-2074:0;
    CHECK(f(0,NULL)==expected);
    Dl_info owner;CHECK(dladdr((const void*)f,&owner));CHECK(f(0,owner.dli_fbase)==expected);
    CHECK(dladdr((const void*)h,&owner));CHECK(f(0,owner.dli_fbase)==-2072);
    CHECK(f(0,&checks)==-2072);CHECK(f(16,NULL)==-1075);CHECK(f(64,NULL)==0);
    fprintf(stderr,"FIPS ABI and startup checks: %u passed\n",checks);return 0;
}
