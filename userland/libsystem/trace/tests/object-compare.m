/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <Foundation/Foundation.h>
#import <os/log.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char**argv){if(argc!=2)return 2;unsigned checks=0,failed=0;void*l=dlopen(argv[1],2);void*h=dlopen("/usr/lib/system/libsystem_trace.dylib",2);char*(*f)(uint32_t,const char**,char*,size_t,void*,void*,uint8_t,const char*,uint8_t*,uint32_t)=dlsym(h,"_os_log_send_and_compose_impl");
__typeof__(f)g=dlsym(l,"_os_log_send_and_compose_impl");
#define P(F,V) do{uint8_t b[__builtin_os_log_format_buffer_size(F,V)];__builtin_os_log_format(b,F,V);char*r=f(2,0,0,0,&__dso_handle,OS_LOG_DEFAULT,0,F,b,sizeof(b));char*q=g(2,0,0,0,&__dso_handle,OS_LOG_DEFAULT,0,F,b,sizeof(b));checks++;if(strcmp(r,q)){fprintf(stderr,"%s: %s | %s\n",F,r,q);failed++;}free(r);free(q);}while(0)
@autoreleasepool{P("object %@",@"hello");P("number %@",@42);P("array %@",(@[@1,@2]));P("nil %@",nil);P("private %{private}@",@"secret");P("public %{public}@",(@[@1,@2]));}printf("log objects: %u checks, %u failures\n",checks,failed);return failed?1:0;}
