/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
struct api {uint32_t(*get)(void);void(*set)(uint32_t);bool(*debug)(void),(*info)(void),(*xpc)(void),(*swift)(void);};
static struct api load(void*h){return (struct api){dlsym(h,"os_trace_get_mode"),dlsym(h,"os_trace_set_mode"),dlsym(h,"os_trace_debug_enabled"),dlsym(h,"os_trace_info_enabled"),dlsym(h,"_os_trace_lazy_init_completed_4libxpc"),dlsym(h,"_os_trace_lazy_init_completed_4swift")};}
static void compare(struct api*a){uint32_t x=a[0].get(),y=a[1].get();if(x!=y){fprintf(stderr,"mode %x != %x\n",x,y);assert(x==y);}assert(a[0].debug()==a[1].debug());assert(a[0].info()==a[1].info());assert(a[0].xpc()==a[1].xpc());assert(a[0].swift()==a[1].swift());}
int main(int argc,char**argv){assert(argc==2);void*h=dlopen("/usr/lib/system/libsystem_trace.dylib",RTLD_NOW|RTLD_LOCAL),*f=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);assert(h&&f);struct api a[]={load(h),load(f)};void*symbols[sizeof(struct api)/sizeof(void*)];memcpy(symbols,a+1,sizeof(symbols));for(unsigned i=0;i<sizeof(symbols)/sizeof(*symbols);i++){Dl_info info;assert(symbols[i]&&dladdr(symbols[i],&info)&&strstr(info.dli_fname,argv[1]));}compare(a);
 uint32_t seed=17;for(unsigned i=0;i<1000;i++){seed=seed*1664525+1013904223;uint32_t mode=seed&~0x100u;for(unsigned j=0;j<2;j++){errno=81;a[j].set(mode);assert(errno==81);errno=83;(void)a[j].get();assert(errno==83);}compare(a);}
 for(unsigned j=0;j<2;j++)a[j].set(0x100);compare(a);for(unsigned j=0;j<2;j++)a[j].set(0);compare(a);puts("mode: 1003 host state comparisons passed");return 0;}
