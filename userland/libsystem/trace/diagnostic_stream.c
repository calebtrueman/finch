/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Live diagnostic messages use the same saved entry layout as stream readers. */
#include "diagnostic_stream.h"
#include "preferences.h"
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>
extern bool _os_trace_mode_match_4tests(uint32_t);
extern xpc_object_t _os_trace_read_plist_at(int,const char*);
extern const char *_os_trace_prefsdir_path(void);
extern xpc_object_t _os_activity_stream_entry_encode(void*,uint64_t);
extern uint64_t voucher_get_activity_id(void*,uint64_t*);
extern void *xpc_pipe_create(const char*,uint64_t);
extern int xpc_pipe_simpleroutine(void*,xpc_object_t);
static pthread_mutex_t filter_lock=PTHREAD_MUTEX_INITIALIZER,pipe_lock=PTHREAD_MUTEX_INITIALIZER;
static uint32_t filter_version;static bool filter_loaded;static xpc_object_t filter;
static void *diagnostic_pipe;

bool finch_trace_filter_matches(xpc_object_t dictionary,const struct finch_trace_filter_subject *s,uint64_t output[2]) {
 if(!dictionary)return false;
 xpc_object_t expression=xpc_dictionary_get_dictionary(dictionary,"logicalExp");
 if(expression) {
  xpc_object_t children=xpc_dictionary_get_array(expression,"subfilters");size_t count=children?xpc_array_get_count(children):0;
  if(!count)return false;xpc_object_t value=xpc_dictionary_get_value(expression,"operator");int64_t op=value?xpc_int64_get_value(value):2;
  if(op<0||op>2||(op==0&&count!=1))return false;
  uint64_t bits[2]={0};bool any=false,all=true;
  for(size_t i=0;i<count;i++){bool match=finch_trace_filter_matches(xpc_array_get_value(children,i),s,bits);any|=match;all&=match;}
  output[0]|=bits[op?0:1];output[1]|=bits[op?1:0];return op==0?!any:op==1?all:any;
 }
 const char *keys[]={"subsystem","category","processImagePath","process","pid","uid"};
 const char *strings[]={s->subsystem,s->category,s->path,s->process};__block bool any=false;
 for(unsigned i=0;i<6;i++) {
  if(i<4&&!strings[i])continue;if(i==4&&s->pid==-1)continue;if(i==5&&s->uid==UINT32_MAX)continue;
  xpc_object_t choices=xpc_dictionary_get_dictionary(dictionary,keys[i]);if(!choices)continue;
  const char *text=i<4?strings[i]:NULL;
  xpc_dictionary_apply(choices,^bool(const char *key,xpc_object_t value){uint64_t bits=xpc_int64_get_value(value);bool match;
   if(i<4)match=(bits&1)?strcasestr(text,key)!=NULL:strcmp(text,key)==0;
   else match=strtoul(key,NULL,10)==(i==4?(uint64_t)(int64_t)s->pid:s->uid);
   output[match?0:1]|=bits;any|=match;return true;});
 }
 return any;
}
static const char *process_path(void){const char *path=_dyld_get_image_name(0);return path?path:getprogname();}
static void subject(struct finch_trace_filter_subject *s,struct finch_log *log) {
 memset(s,0,sizeof(*s));s->path=process_path();const char *slash=s->path?strrchr(s->path,'/'):NULL;s->process=slash?slash+1:s->path;s->pid=getpid();s->uid=geteuid();
 if(log&&log->names){s->subsystem=log->names->names;s->category=s->subsystem+log->names->subsystem_size;}
}
bool finch_trace_stream_enabled(unsigned kind,uint8_t level,struct finch_log *log) {
 if(_os_trace_mode_match_4tests(0x500)||!_os_trace_mode_match_4tests(8))return false;
 int saved=errno;uint32_t generation=finch_trace_preferences_version();pthread_mutex_lock(&filter_lock);
 if(!filter_loaded||filter_version!=generation){if(filter)xpc_release(filter);char path[1024];snprintf(path,sizeof(path),"%s/com.apple.diagnosticd.filter.plist",_os_trace_prefsdir_path());filter=_os_trace_read_plist_at(AT_FDCWD,path);filter_version=generation;filter_loaded=true;}
 uint64_t bits=UINT64_C(0xb00070000),results[2]={0};struct finch_trace_filter_subject s;subject(&s,NULL);
 if(filter){bool match=finch_trace_filter_matches(filter,&s,results);bits=(match?results[0]:0)|(uint64_t)xpc_dictionary_get_int64(filter,"global");}
 uint32_t levels=bits>>32,kinds=(uint32_t)(bits>>16);unsigned wanted=level==2?2:level==1?1:8;
 bool enabled=(kinds&kind)&&(kind==1||kind==8||(levels&wanted));
 if(!enabled&&(kind==4||kind==8)&&filter&&log){subject(&s,log);results[0]=results[1]=0;if(finch_trace_filter_matches(filter,&s,results)){
  uint32_t selected=results[0]>>32;
  if(kind==8)enabled=!!(results[0]&0x80000);
  else enabled=!(results[0]&0x40000)||(selected&2)||((selected&1)&&level!=2)||((selected&8)&&level!=1&&level!=2);
 }}
 if(kind==8&&log&&!((log->options>>32)&0x400000))enabled=false;
 if(kind==4&&log&&((log->options>>32)&7)==4)enabled=false;
 pthread_mutex_unlock(&filter_lock);errno=saved;return enabled;
}
static void put64(unsigned char *entry,size_t offset,uint64_t value){memcpy(entry+offset,&value,8);}
static void put32(unsigned char *entry,size_t offset,uint32_t value){memcpy(entry+offset,&value,4);}
static void putptr(unsigned char *entry,size_t offset,const void *p){put64(entry,offset,(uintptr_t)p);}
static bool image_uuid(const struct mach_header *header,unsigned char uuid[16]) {
 if(!header)return false;size_t hsize=header->magic==MH_MAGIC_64?sizeof(struct mach_header_64):sizeof(struct mach_header);const unsigned char *p=(const void*)header;p+=hsize;
 size_t left=header->sizeofcmds;for(uint32_t i=0;i<header->ncmds&&left>=8;i++){const struct load_command *c=(const void*)p;if(c->cmdsize<8||c->cmdsize>left)return false;if(c->cmd==LC_UUID&&c->cmdsize>=sizeof(struct uuid_command)){memcpy(uuid,((const struct uuid_command*)c)->uuid,16);return true;}p+=c->cmdsize;left-=c->cmdsize;}return false;
}
static void *pipe_get(void *broken) {
 pthread_mutex_lock(&pipe_lock);
 if(broken&&diagnostic_pipe==broken){xpc_release(diagnostic_pipe);diagnostic_pipe=NULL;}
 if(!diagnostic_pipe)diagnostic_pipe=xpc_pipe_create("com.apple.diagnosticd",2);
 void *result=diagnostic_pipe;if(result)xpc_retain(result);pthread_mutex_unlock(&pipe_lock);return result;
}
void finch_trace_stream_send(const struct finch_trace_stream_event *event,void(^payload)(xpc_object_t)) {
 int saved=errno;void *pipe=pipe_get(NULL);if(!pipe){errno=saved;return;}
 unsigned char entry[236]={0},procuuid[16]={0},imageuuid[16]={0};uint8_t space=event->identifier;
 uint32_t type=space==3||space==4||space==6||space==8?(uint32_t)space<<8:((uint32_t)event->identifier&255)<<8|((uint32_t)event->identifier>>8&255);
 xpc_object_t extra=NULL;
 if(type==0x300&&payload){extra=xpc_dictionary_create(NULL,NULL,0);payload(extra);if(!xpc_dictionary_get_count(extra)){xpc_release(extra);extra=NULL;}}
 put32(entry,0,type);put32(entry,4,getpid());put32(entry,16,geteuid());
 struct {unsigned char uuid[16];uint64_t unique,parent;int32_t version,parentversion;uint64_t spare[2];} info={0};
 if(proc_pidinfo(getpid(),17,0,&info,sizeof(info))==sizeof(info)){memcpy(procuuid,info.uuid,16);put64(entry,8,info.unique);putptr(entry,20,procuuid);}
 putptr(entry,28,process_path());uint64_t parent=0;put64(entry,36,voucher_get_activity_id(event->activity?event->activity:(void*)-3,&parent));put64(entry,44,parent);
 put64(entry,52,event->identifier);put64(entry,60,event->timestamp?event->timestamp:mach_continuous_time());uint64_t thread=0;pthread_threadid_np(NULL,&thread);put64(entry,68,thread);
 const void *image=event->image;const void *pc=ptrauth_strip(event->pc,ptrauth_key_return_address);Dl_info dl={0};if(!image&&pc&&dladdr(pc,&dl))image=dl.dli_fbase;
 if(!image_uuid(image,imageuuid)){if(extra)xpc_release(extra);xpc_release(pipe);errno=saved;return;}
 putptr(entry,76,imageuuid);if(dladdr(image,&dl))putptr(entry,84,dl.dli_fname);
 put64(entry,116,(uintptr_t)pc-(uintptr_t)image);put64(entry,124,event->format_offset);
 struct timeval now;if(event->wall&&event->wall->tv_sec){now.tv_sec=event->wall->tv_sec;now.tv_usec=(int32_t)(event->wall->tv_nsec/1000);}else gettimeofday(&now,NULL);
 put64(entry,92,now.tv_sec);put32(entry,100,now.tv_usec);struct tm local={0};localtime_r(&now.tv_sec,&local);put32(entry,108,(uint32_t)(-local.tm_gmtoff/60+local.tm_isdst*60));put32(entry,112,local.tm_isdst);
 putptr(entry,140,event->name);putptr(entry,148,event->buffer);put64(entry,156,event->buffer_size);
 if(type==0x300)putptr(entry,164,extra);
 else if(type==0x400||type==0x600||type==0x800){putptr(entry,164,event->private_data);put64(entry,172,event->private_size);if(event->log&&event->log->names){putptr(entry,180,event->log->names->names);putptr(entry,188,event->log->names->names+event->log->names->subsystem_size);}entry[200]=event->ttl;entry[201]=event->persisted;put64(entry,204,event->signpost_id);putptr(entry,212,event->signpost_name);}
 else if(type==0x203)entry[148]=event->persisted;
 xpc_object_t message=_os_activity_stream_entry_encode(entry,2);
 if(message){__block void *active=pipe;dispatch_block_perform(DISPATCH_BLOCK_DETACHED,^{for(;;){int result=xpc_pipe_simpleroutine(active,message);if(result!=EPIPE)break;void *next=pipe_get(active);if(active!=pipe)xpc_release(active);active=next;if(!active)break;}});if(active&&active!=pipe)xpc_release(active);xpc_release(message);}
 if(extra)xpc_release(extra);xpc_release(pipe);errno=saved;
}
void finch_trace_stream_fork_child(void){filter_lock=(pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;pipe_lock=(pthread_mutex_t)PTHREAD_MUTEX_INITIALIZER;filter=NULL;filter_loaded=false;diagnostic_pipe=NULL;}
