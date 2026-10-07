/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../preferences.h"
#include <Block.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <errno.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
extern bool _os_trace_atm_diagnostic_config(uint32_t*);
extern kern_return_t _os_trace_set_diagnostic_flags(uint32_t);
extern bool _os_trace_mode_match_4tests(uint32_t);
extern void _os_trace_update_with_datavolume_4launchd(void);
extern uint32_t _os_trace_commpage_compute(uint32_t,int,int,int,int);
static const char*bootargs;
static uint32_t mode,requested_flags;
static uint64_t activity;
static unsigned flag_calls,port_frees,cache_calls,vm_frees,fixture;
static uint32_t cache_version=6;
static unsigned char *cache_fixture;
static size_t cache_fixture_size;
extern uint64_t os_simple_hash(const void*,size_t);
static bool variant_full,variant_recovery,variant_internal;
static void(^notification)(int);
uint32_t os_trace_get_mode(void){return mode;}
int test_preferences_sysctl(const char*name,void*out,size_t*length,void*new_value,size_t new_length){assert(!strcmp(name,"kern.bootargs")&&!new_value&&!new_length);if(!bootargs)return -1;size_t n=strlen(bootargs)+1;assert(*length>=n);memcpy(out,bootargs,n);*length=n;return 0;}
mach_port_t test_preferences_host_self(void){return 123;}
kern_return_t test_preferences_set_flags(host_t host,uint32_t flags){assert(host==123);requested_flags=flags;flag_calls++;return KERN_NO_ACCESS;}
kern_return_t test_preferences_port_free(ipc_space_t task,mach_port_name_t name){assert(task==mach_task_self()&&name==123);port_frees++;return KERN_SUCCESS;}
bool test_preferences_variant(const char*domain,const char*name){assert(!strcmp(domain,"com.apple.libtrace")&&!strcmp(name,"HasFullLogging"));return variant_full;}
bool test_preferences_recovery(const char*domain){assert(!strcmp(domain,"com.apple.libtrace"));return variant_recovery;}
bool test_preferences_internal(const char*domain){assert(!strcmp(domain,"com.apple.libtrace"));return variant_internal;}
uint32_t test_preferences_notify(const char*name,int*token,dispatch_queue_t queue,void(^handler)(int)){assert(!strcmp(name,"com.apple.system.logging.prefschanged")&&queue);*token=7;notification=Block_copy(handler);return 0;}
uint64_t test_preferences_activity(void*current,uint64_t*parent){assert(current==(void*)(intptr_t)-3&&!parent);return activity;}
void *test_preferences_cache(size_t*length){cache_calls++;if(cache_fixture){void*p=malloc(cache_fixture_size);memcpy(p,cache_fixture,cache_fixture_size);*length=cache_fixture_size;return p;}uint32_t*p=malloc(12);p[0]=cache_version;p[1]=17;p[2]=42;*length=12;return p;}
kern_return_t test_preferences_vm_free(vm_map_t task,mach_vm_address_t address,mach_vm_size_t size){assert(task==mach_task_self()&&size==(cache_fixture?cache_fixture_size:12));vm_frees++;free((void*)(uintptr_t)address);return KERN_SUCCESS;}
static xpc_object_t level(const char*name){xpc_object_t root=xpc_dictionary_create(NULL,NULL,0),category=xpc_dictionary_create(NULL,NULL,0),lev=xpc_dictionary_create(NULL,NULL,0);xpc_dictionary_set_string(lev,"Enable",name);xpc_dictionary_set_value(category,"Level",lev);xpc_dictionary_set_value(root,"category",category);xpc_release(lev);xpc_release(category);return root;}
xpc_object_t test_preferences_bundle(void){xpc_object_t bundle=xpc_dictionary_create(NULL,NULL,0),prefs=xpc_dictionary_create(NULL,NULL,0),sub=level("debug");xpc_dictionary_set_value(prefs,"test",sub);xpc_dictionary_set_value(bundle,"OSLogPreferences",prefs);xpc_release(sub);xpc_release(prefs);return bundle;}
xpc_object_t test_preferences_bundle_info(xpc_object_t bundle){return bundle;}
void *test_preferences_read(int dir,const char*path,size_t limit,size_t*length){(void)dir;assert(limit==65536);*length=0;const char*name=NULL;if(strstr(path,"/System/Cryptexes/App/")){if(fixture==1)name="off";}else if(strstr(path,"/System/Cryptexes/OS/")){if(fixture==2)name="debug";}else if(strstr(path,"/System/Library/"))name="info";else if(strstr(path,"/Library/Preferences/Logging/")&&fixture==3)name="default";if(!name)return NULL;char*bytes=NULL;assert(asprintf(&bytes,"<plist version=\"1.0\"><dict><key>category</key><dict><key>Level</key><dict><key>Enable</key><string>%s</string></dict></dict></dict></plist>",name)>0);*length=strlen(bytes);return bytes;}
static size_t record(unsigned char*p,const char*name,struct finch_log_preferences options){uint32_t n=(uint32_t)strlen(name),size=20+((n+4)&~3u),hash=(uint32_t)os_simple_hash(name,n);memset(p,0,size);memcpy(p,&size,4);memcpy(p+4,&n,4);memcpy(p+8,&hash,4);memcpy(p+12,&options,8);memcpy(p+20,name,n);return size;}
static void cache_records(void){
 unsigned char bytes[1024],original[1024];memset(bytes,0,sizeof(bytes));uint32_t version=6;memcpy(bytes,&version,4);struct finch_log_preferences base={0,4,5,6,0x753abc},specific={0,7,8,9,0x345123};
 size_t first=record(bytes+4,"unrelated",base),start=4+first,header=record(bytes+start,"cached",base),cat=record(bytes+start+header,"category",specific),total=header+cat;uint32_t total32=(uint32_t)total;memcpy(bytes+start,&total32,4);size_t length=start+total;
 struct finch_log_preferences output;assert(finch_trace_preferences_cached(bytes,length,"cached","category",&output)&&!memcmp(&output,&specific,8));assert(finch_trace_preferences_cached(bytes,length,"cached","missing",&output)&&!memcmp(&output,&base,8));assert(finch_trace_preferences_cached(bytes,length,"missing","category",&output)&&output.options==0x450000);assert(finch_trace_preferences_cached(bytes,length,"cached","DynamicTracing",&output)&&output.options==(base.options&~0x40000u));assert(finch_trace_preferences_cached(bytes,length,"cached","DynamicStackTracing",&output)&&output.options==((base.options&~0x340000u)|0x100000));
 /* Compare the host's private record reader from this exact inspected build.
    The exported compute symbol provides the image anchor; no replacement symbol lookup is used. */
 void*host=dlopen("/usr/lib/system/libsystem_trace.dylib",RTLD_NOW|RTLD_LOCAL);void*anchor=dlsym(host,"_os_log_preferences_compute");Dl_info info;assert(anchor&&dladdr(anchor,&info)&&strstr(info.dli_fname,"/libsystem_trace.dylib"));uintptr_t address=(uintptr_t)ptrauth_strip(anchor,ptrauth_key_function_pointer)-0xd35c+0x42f4;
 const unsigned char*(*find)(const void*,size_t,const char*)=ptrauth_sign_unauthenticated((void*)address,ptrauth_key_function_pointer,0);
 memcpy(original,bytes,sizeof(bytes));unsigned comparisons=0;for(unsigned mutation=0;mutation<32;mutation++)for(size_t size=0;size<=length;size++){
  memcpy(bytes,original,sizeof(bytes));if(mutation){size_t off=(mutation-1)%20;bytes[4+off]^=(unsigned char)(mutation*17);}
  for(unsigned name=0;name<3;name++){const char*key=(const char*[]){"cached","unrelated","missing"}[name];const unsigned char*a=find(bytes+4,size,key),*b=finch_trace_preferences_find_record(bytes+4,size,key);assert(a==b);comparisons++;}
 }
 memcpy(bytes,original,sizeof(bytes));for(size_t size=0;size<4;size++)assert(!finch_trace_preferences_cached(bytes,size,"cached","category",&output));
 cache_fixture=bytes;cache_fixture_size=length;cache_version=6;struct {uint16_t id;uint8_t subsystem_size,category_size;char text[32];} names;memset(&names,0,sizeof(names));memcpy(names.text,"cached\0category",16);names.subsystem_size=7;struct finch_log log={.names=(struct finch_log_names*)&names,.options=UINT64_C(0x4400000000000000)};errno=91;finch_trace_preferences_refresh(&log);memcpy(&output,&log.options,8);specific.options=(specific.options&~0x7c000000u)|0x44000000u;assert(!memcmp(&output,&specific,8)&&errno==91&&log.generation==finch_trace_preferences_version());
 /* Bundle entries take priority over the daemon cache. */
 memcpy(names.text,"test\0category",14);names.subsystem_size=5;unsigned calls=cache_calls;fixture=0;finch_trace_preferences_refresh(&log);assert(cache_calls==calls&&((log.options>>32)&7)==3);
 cache_fixture=NULL;cache_fixture_size=0;printf("cache records: %u host comparisons and runtime selection checks passed\n",comparisons);
}
int main(void){
 const struct {const char*text;bool success;uint32_t value;} cases[]={{NULL,false,0},{"",false,0},{"abc=4",false,0},{"atm_diagnostic_config=123",true,0x123},{"other=5 ATM_DIAGNOSTIC_CONFIG=0xff rest",true,255},{"atm_diagnostic_config=1G",false,0},{"atm_diagnostic_config=",true,0},{"atm_diagnostic_config= ",true,0},{"atm_diagnostic_config=-1",true,UINT32_MAX},{"atm_diagnostic_config=42\tmore",true,0x42},{"atm_diagnostic_config=0x123456789",true,0x23456789}};
 for(size_t i=0;i<sizeof(cases)/sizeof(*cases);i++){bootargs=cases[i].text;uint32_t value=0xa5a5a5a5;assert(_os_trace_atm_diagnostic_config(&value)==cases[i].success);assert(value==(cases[i].success?cases[i].value:0xa5a5a5a5));}
 assert(_os_trace_set_diagnostic_flags(0x12345678)==KERN_NO_ACCESS);assert(requested_flags==0x12345678&&flag_calls==1&&port_frees==1);
 for(unsigned combination=0;combination<8;combination++){variant_full=combination&1;variant_recovery=combination&2;variant_internal=combination&4;uint32_t old=*(const volatile uint32_t*)(uintptr_t)UINT64_C(0xfffffc104),expected=_os_trace_commpage_compute(old,variant_recovery,0,variant_internal,variant_full);unsigned before=flag_calls;_os_trace_update_with_datavolume_4launchd();assert(flag_calls==before+(expected!=old)&&flag_calls==port_frees);if(expected!=old)assert(requested_flags==expected);}
 assert(finch_trace_preferences_version()==0&&notification);notification(7);assert(finch_trace_preferences_version()==1);notification(7);assert(finch_trace_preferences_version()==2);mode=2;assert(_os_trace_mode_match_4tests(2));mode=0;activity=UINT64_C(8)<<56;assert(_os_trace_mode_match_4tests(8));assert(!_os_trace_mode_match_4tests(0));
 size_t size=0;uint32_t*cache=_os_log_preferences_copy_cache(&size);assert(cache&&size==(cache_fixture?cache_fixture_size:12)&&cache[0]==6&&cache[1]==17&&cache[2]==42&&cache_calls==1&&vm_frees==1);free(cache);cache_version=5;assert(!_os_log_preferences_copy_cache(&size)&&!size&&cache_calls==2&&vm_frees==2);mode=0x100;assert(!_os_log_preferences_copy_cache(&size)&&!size&&cache_calls==2);mode=0;
 for(fixture=0;fixture<4;fixture++){xpc_object_t p=_os_log_preferences_load_sysprefs("test",NULL,true);struct finch_log_preferences result;_os_log_preferences_compute(p,"category",&result);assert((result.options&7)==(fixture==1?4:fixture==2?3:2));xpc_release(p);p=_os_log_preferences_load("test",NULL);_os_log_preferences_compute(p,"category",&result);assert((result.options&7)==(fixture==3?1:3));xpc_release(p);}
 cache_records();
 Block_release(notification);puts("preferences wire: boot flags, Mach cleanup, notifications, cache validation, bundle and file priority pass");return 0;
}
