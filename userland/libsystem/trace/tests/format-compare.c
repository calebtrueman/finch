/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <os/log.h>
#include <errno.h>
#include <string.h>
static char*(*local)(const char*,const uint8_t*,size_t,int,char*,size_t);
static unsigned checks,failed;
static char*(*compose)(uint32_t,const char**,char*,size_t,void*,void*,uint8_t,const char*,uint8_t*,uint32_t);
#define P(F,...) do{uint8_t b[__builtin_os_log_format_buffer_size(F,##__VA_ARGS__)];__builtin_os_log_format(b,F,##__VA_ARGS__);size_t caps[]={0,1,4,16,1024};for(unsigned ci=0;ci<5;ci++){char tmp[1024],ours[1024];size_t cap=caps[ci];memset(tmp,0xa5,sizeof(tmp));memset(ours,0xa5,sizeof(ours));int err=errno;char*r=compose(2,0,cap?tmp:NULL,cap,&__dso_handle,OS_LOG_DEFAULT,0,F,b,sizeof(b));char*q=local(F,b,sizeof(b),err,cap?ours:NULL,cap);checks++;if(!r||!q||strcmp(r,q)||(r==tmp)!=(q==ours)){if(failed++<30)fprintf(stderr,"%s cap %zu: host [%s] local [%s]\n",F,cap,r?r:"NULL",q?q:"NULL");}if(r&&r!=tmp)free(r);if(q&&q!=ours)free(q);}}while(0)

int main(int argc,char**argv){if(argc!=2)return 2;void*l=dlopen(argv[1],2);local=dlsym(l,"finch_log_compose");if(!local)return 2;void*h=dlopen("/usr/lib/system/libsystem_trace.dylib",2);compose=dlsym(h,"_os_log_send_and_compose_impl");P("plain");P("number %{mask.hash}d",42);P("number %{public,mask.hash}d",42);P("bool %{BOOL}d",-1);P("yes %{BOOL}d",0);P("iec %{iec-bytes}llu",12345678ull);P("bytes %{bytes}llu",12345678ull);P("bitrate %{bitrate}d",1234567);P("duration %{duration}d",1234);P("network %{network:in_addr}d",0x0100007f);P("uuid %{public,uuid_t}.16P","0123456789abcdef");P("pointer %{private}p",(void*)0x1234);P("quoted %{public}.3s","abcdef");P("wide %ls",L"hello");P("char %c",65);P("int %d %u %llx",-42,42u,0x123456789ull);P("string %s","hello");P("string %{public}s","hello");P("string %{private}s","hello");P("number %{private}d",42);P("float %8.2f",1.25);P("pad %*.*f",8,3,1.25);P("data %.*P",3,"abc");P("data %{public}.*P",3,"abc");P("bool %{bool}d",2);P("errno %{errno}d",2);P("time %{time_t}d",0);P("ptr %p",(void*)0x1234);P("err %m");P("null %s",(char*)0);for(int i=-20;i<=20;i++){P("signed %d %+06d %#x %hhd %hhu",i,i,(unsigned)i,i,(unsigned)i);P("float %.4f %g %a",i/3.0,i/7.0,i/9.0);P("stars %*.*f",i,i<0?0:i%7,i/3.0);P("string %*.*s",i,i<0?0:i%7,"abcdef");P("private %{private}d %{private}s",i,"secret");P("wide integer %lld %llu",(long long)i*123456789,(unsigned long long)i*123456789);P("units %{bytes}llu %{iec-bytes}llu %{bitrate}llu",(unsigned long long)i*123456789,(unsigned long long)i*123456789,(unsigned long long)i*123456789);}
 for(int e=0;e<16;e++){errno=e;P("error %m");}
 P("empty");P("");P("percent %% %d %%",7);P("letters %c %c",0,255);P("nil %p",(void*)0);
 printf("log composition: %u checks, %u failures\n",checks,failed);return failed?1:0;}
