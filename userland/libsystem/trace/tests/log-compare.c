/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../internal.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <Block.h>
#include <errno.h>
extern char __dso_handle;
struct api {
 void*default_log,*disabled_log;void*(*create)(const char*,const char*);bool(*enabled)(void*,uint8_t);size_t(*pack_size)(size_t);uint8_t*(*fill)(void*,size_t,int,void*,const char*);
 char*(*compose)(uint32_t,const char**,char*,size_t,void*,void*,uint8_t,const char*,uint8_t*,uint32_t);
 char*(*pack_compose)(void*,void*,uint8_t,char*,size_t);void(*send)(void*,void*,uint8_t,const char*,uint8_t*,uint32_t);
 void*(*hook)(uint8_t,void(^)(uint8_t,const struct finch_log_message*));char*(*copy)(const struct finch_log_message*);char*(*decorated)(uint8_t,const struct finch_log_message*);
};
static unsigned checks,failed;
#define C(X) do{checks++;if(!(X)){if(failed++<20)fprintf(stderr,"line %d: %s\n",__LINE__,#X);}}while(0)
static void bind(struct api*a,void*h){
#define B(F,S) do{*(void**)(&a->F)=dlsym(h,S);if(!a->F){fprintf(stderr,"missing %s\n",S);exit(2);}}while(0)
 B(default_log,"_os_log_default");B(disabled_log,"_os_log_disabled");B(create,"os_log_create");B(enabled,"os_log_type_enabled");B(pack_size,"_os_log_pack_size");B(fill,"_os_log_pack_fill");B(compose,"_os_log_send_and_compose_impl");B(pack_compose,"os_log_pack_compose");B(send,"_os_log_impl");B(hook,"os_log_set_hook");B(copy,"os_log_copy_message_string");B(decorated,"os_log_copy_decorated_message");
}
static struct api a[2];static unsigned calls[2];static unsigned char wire[2][4096];static size_t wire_len[2];
#define MESSAGE(F,...) do{uint8_t data[__builtin_os_log_format_buffer_size(F,##__VA_ARGS__)];__builtin_os_log_format(data,F,##__VA_ARGS__);for(int k=0;k<2;k++){a[k].send(&__dso_handle,a[k].default_log,0,F,data,sizeof(data));}if(wire_len[0]!=wire_len[1]||memcmp(wire[0],wire[1],wire_len[0])){fprintf(stderr,"FORMAT %s\n",F);for(int k=0;k<2;k++){for(size_t i=0;i<wire_len[k];i++)fprintf(stderr,"%02x",wire[k][i]);fprintf(stderr,"\n");}}C(wire_len[0]==wire_len[1]);C(!memcmp(wire[0],wire[1],wire_len[0]));}while(0)
int main(int argc,char**argv){if(argc!=2)return 2;void*h[2]={dlopen("/usr/lib/system/libsystem_trace.dylib",2),dlopen(argv[1],2)};if(!h[1]){puts(dlerror());return 2;}for(int k=0;k<2;k++)bind(a+k,h[k]);
 for(int i=0;i<30;i++){char name[40];snprintf(name,sizeof(name),"finch.compare.%d",i);void*l[2];for(int k=0;k<2;k++){l[k]=a[k].create(name,"tests");C(l[k]==a[k].create(name,"tests"));}for(int t=0;t<20;t++){C(a[0].enabled(l[0],t)==a[1].enabled(l[1],t));C(a[0].enabled(a[0].disabled_log,t)==a[1].enabled(a[1].disabled_log,t));}}
 const char*format="number %d";unsigned char data[]={0,1,0,4,42,0,0,0};
 for(size_t n=0;n<128;n++){C(a[0].pack_size(n)==a[1].pack_size(n));unsigned char pack[2][256];for(int k=0;k<2;k++){memset(pack[k],0xa5,256);uint8_t*p=a[k].fill(pack[k],a[k].pack_size(n),12,&__dso_handle,format);C(p==pack[k]+68);}C(!memcmp(pack[0],pack[1],32));C(!memcmp(pack[0]+40,pack[1]+40,216));}
 for(int k=0;k<2;k++){unsigned char pack[256];uint8_t*p=a[k].fill(pack,a[k].pack_size(sizeof(data)),0,&__dso_handle,format);memcpy(p,data,sizeof(data));char buf[100];char*s=a[k].pack_compose(pack,a[k].default_log,0,buf,sizeof(buf));C(s==buf);C(!strcmp(s,"number 42"));}
 for(int k=0;k<2;k++){int index=k;a[k].hook(2,^(uint8_t type,const struct finch_log_message*m){calls[index]++;C(type==0);C(m->thread!=0);C(m->timestamp!=0);C(m->data_size<sizeof(wire[index]));wire_len[index]=m->data_size;memcpy(wire[index],m->data,m->data_size);char*x=a[0].copy(m),*y=a[1].copy(m);if(!x||!y||strcmp(x,y))fprintf(stderr,"COPY %s | %s\n",x?x:"NULL",y?y:"NULL");C(x&&y&&!strcmp(x,y));free(x);free(y);x=a[0].decorated(type,m);y=a[1].decorated(type,m);C(x&&y&&!strcmp(x,y));free(x);free(y);});}
 MESSAGE("hello");MESSAGE("values %d %u %llx",-42,15u,0x123456789ull);MESSAGE("strings %s %{public}s %{private}s","default","public","private");MESSAGE("private %{private}d %{private}llx",42,0x123456ull);MESSAGE("data %.*P %{public}.*P",3,"abc",3,"abc");MESSAGE("null %s %{public}s",(char*)NULL,(char*)NULL);MESSAGE("precision %.3s %.*s","abcdef",3,"abcdef");MESSAGE("errno %m");C(calls[0]==calls[1]);C(calls[0]==8);
 printf("logging ABI: %u checks, %u failures\n",checks,failed);return failed?1:0;
}
