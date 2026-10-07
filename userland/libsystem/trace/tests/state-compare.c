/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../state.h"
#include <dlfcn.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(int argc,char**argv){assert(argc==2);void*h=dlopen("/usr/lib/system/libsystem_trace.dylib",RTLD_NOW|RTLD_LOCAL),*f=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);assert(h&&f);uint64_t(*add[2])(dispatch_queue_t,finch_state_handler)={dlsym(h,"os_state_add_handler"),dlsym(f,"os_state_add_handler")};void(*remove[2])(uint64_t)={dlsym(h,"os_state_remove_handler"),dlsym(f,"os_state_remove_handler")};Dl_info info;assert(dladdr((void*)add[1],&info)&&strstr(info.dli_fname,argv[1]));dispatch_queue_t q=dispatch_queue_create("finch.state.compare",DISPATCH_QUEUE_SERIAL);uint64_t ids[2][256];for(unsigned i=0;i<256;i++)for(unsigned j=0;j<2;j++){ids[j][i]=add[j](q,^struct finch_state_data*(const struct finch_state_hints*hints){(void)hints;return NULL;});assert(ids[j][i]);if(i)assert(ids[j][i]==ids[j][i-1]+1);}dispatch_release(q);for(unsigned i=0;i<256;i++)for(unsigned j=0;j<2;j++){remove[j](ids[j][(i*31)%256]);remove[j](ids[j][(i*31)%256]);}for(unsigned j=0;j<2;j++){remove[j](0);remove[j](UINT64_MAX);}puts("state: 256 host registrations and repeat/unknown removals match");return 0;}
