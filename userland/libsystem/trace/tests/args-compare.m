/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <Foundation/Foundation.h>
#include "../internal.h"
#include <dlfcn.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
struct api {void*log;void*(*hook)(uint8_t,void(^)(uint8_t,const struct finch_log_message*));char*(*copy)(const struct finch_log_message*);void(*args)(void*,uint8_t,const char*,va_list,void*);void(*cf)(void*,void*,unsigned,void*,va_list);};
static struct api a[2];static char*message[2];static uint8_t types[2];static unsigned checks;static bool no_address;
static void plain(const char*format,...){for(int i=0;i<2;i++){va_list ap;va_start(ap,format);a[i].args(a[i].log,0,format,ap,no_address?NULL:(void*)plain);va_end(ap);}assert(message[0]&&message[1]);if(strcmp(message[0],message[1])){fprintf(stderr,"format %s: [%s]/[%s]\n",format,message[0],message[1]);abort();}checks++;}
static void cf(unsigned type,NSString*format,...){for(int i=0;i<2;i++){va_list ap;va_start(ap,format);a[i].cf(NULL,a[i].log,type,(void*)format,ap);va_end(ap);}assert(message[0]&&message[1]);if(strcmp(message[0],message[1])){fprintf(stderr,"cf format %s: [%s]/[%s]\n",format.UTF8String,message[0],message[1]);abort();}assert(types[0]==types[1]);checks++;}
int main(int argc,char**argv){assert(argc==2);void*h[2]={dlopen("/usr/lib/system/libsystem_trace.dylib",2),dlopen(argv[1],2)};assert(h[0]&&h[1]);for(int i=0;i<2;i++){a[i].log=dlsym(h[i],"_os_log_default");a[i].hook=dlsym(h[i],"os_log_set_hook");a[i].copy=dlsym(h[i],"os_log_copy_message_string");a[i].args=dlsym(h[i],"os_log_with_args");a[i].cf=dlsym(h[i],"os_log_shim_with_CFString");a[i].hook(2,^(uint8_t type,const struct finch_log_message*m){free(message[i]);message[i]=a[i].copy(m);types[i]=type;});}
 @autoreleasepool{plain("hello");plain("i=%d u=%u x=%x",-42,123u,0xffu);plain("wide=%lld",(long long)-12345678901);plain("stars %*.*f",12,3,1.23456);plain("string %s","hello");plain("public %{public}s","hello");plain("object %@",@"hello");plain("unicode %@",@"hello 日本語");for(unsigned type=0;type<20;type++){cf(type,@"value %d %@",42,@"hello");cf(type,@"日本語 %d",42);}}
 no_address=true;plain("hello");plain("number %d",42);plain("object %@",@"hello");for(int i=0;i<2;i++)a[i].cf=dlsym(h[i],"os_log_shim_with_CFString_4NSLog");cf(0,@"value %d %@",42,@"hello");cf(0,@"日本語 %d",42);
 printf("runtime log arguments: %u host comparisons passed\n",checks);return 0;}
