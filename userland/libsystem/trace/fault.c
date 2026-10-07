/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "fault.h"
#include "state.h"
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <errno.h>
extern bool _os_trace_mode_match_4tests(uint32_t);
extern bool _os_trace_is_development_build(void);
extern const void *dyld_image_header_containing_address(const void*);
extern void *_os_activity_create(const void*,const char*,void*,unsigned);
extern void *voucher_adopt(void*);
extern uint64_t voucher_get_activity_id(void*,uint64_t*);
extern void os_release(void*);
extern void os_fault_with_payload(uint32_t,uint64_t,const void*,uint32_t,const char*,uint64_t);
extern bool finch_trace_lazy_initialized(void);
extern bool os_log_type_enabled(struct finch_log*,uint8_t);
extern void _os_log_fault_impl(const void*,struct finch_log*,uint8_t,const char*,const void*,uint32_t);
static _Atomic bool quarantined;
static dispatch_once_t report_once;static unsigned report_mode;
static void report_init(void *unused){(void)unused;const char *value=getenv("OS_LOG_FAULT_REPORTS");if(value&&!strcasecmp(value,"always"))report_mode=2;else if(value&&!strcasecmp(value,"off"))report_mode=3;}
bool finch_trace_fault_report_enabled(uint32_t options,unsigned mode,bool development,bool first){
 unsigned setting=(options>>23)&3;if(setting==2)return true;if(setting!=1)return false;
 if(mode==2)return true;if(mode==3)return false;return development&&first;
}
static char *compose(const struct finch_log_pack *pack,const uint8_t *data,size_t size){return finch_log_compose(pack&&pack->format?pack->format:"",data,size,pack?pack->error:0,NULL,0);}
static void fault_report(struct finch_log *log,const struct finch_log_pack *pack,const uint8_t *data,size_t size){
 char *message=compose(pack,data,size);if(!message)return;
 size_t subsystem=log&&log->names?log->names->subsystem_size:0,category=log&&log->names?log->names->category_size:0;
 size_t names=subsystem+category,text=strlen(message)+1,available=2048-20-names;
 if(text>available){text=available;if(text>=4)memcpy(message+text-4,"...",4);else message[text-1]=0;}
 size_t bytes=20+names+text;unsigned char *packet=calloc(1,bytes);if(!packet){free(message);return;}
 uint32_t header[5]={1,0,0,0,(uint32_t)(20+names)};
 if(names){header[2]=20;header[3]=(uint32_t)(20+subsystem);memcpy(packet+20,log->names->names,names);}
 memcpy(packet,header,20);memcpy(packet+20+names,message,text);
 uint32_t options=log?(uint32_t)(log->options>>32):0;
 os_fault_with_payload(18,5,packet,(uint32_t)bytes,pack?pack->format:NULL,(options>>14)&0x800);
 free(packet);free(message);
}
struct finch_trace_fault_scope finch_trace_fault_begin(struct finch_log *log,uint8_t type,const struct finch_log_pack *pack,const uint8_t *data,size_t size,bool unreliable,bool first,uint8_t ttl){
 struct finch_trace_fault_scope scope={0};uint8_t level=type&0x7f;
 if(unreliable||_os_trace_mode_match_4tests(0x500)||(level!=17&&!(type&0x80)))return scope;
 int saved=errno;
 if(level==17){dispatch_once_f(&report_once,NULL,report_init);uint32_t options=log?(uint32_t)(log->options>>32):0;
  if(finch_trace_fault_report_enabled(options,report_mode,_os_trace_is_development_build(),first))fault_report(log,pack,data,size);
 }
 const void *image=dyld_image_header_containing_address((const void*)finch_trace_fault_begin);
 void *activity=_os_activity_create(image,"Activity for state dumps",(void*)-3,0);
 uint64_t identifier=voucher_get_activity_id(activity,NULL);scope.previous=voucher_adopt(activity);scope.active=true;
 struct finch_state_hints hints={.version=1,.type=level==17?2:1,.flags=1};
 finch_trace_state_request(identifier,&hints,ttl,pack?pack->image:NULL);errno=saved;return scope;
}
void finch_trace_fault_end(struct finch_trace_fault_scope *scope){if(!scope||!scope->active)return;int saved=errno;void *current=voucher_adopt(scope->previous);if(current)os_release(current);*scope=(struct finch_trace_fault_scope){0};errno=saved;}
void finch_trace_fault_callbacks(struct finch_log *log,uint8_t type,const struct finch_log_pack *pack,const uint8_t *data,size_t size,finch_trace_message_callback fault,finch_trace_message_callback test){
 const char *subsystem=log&&log->names?log->names->names:NULL,*category=subsystem?subsystem+log->names->subsystem_size:NULL;
 bool skip=subsystem&&category&&!strncmp(subsystem,"com.apple.runtime-issues",25)&&!strncmp(category,"SkipRuntimeIssues",18);
 if((type&0x7f)!=17||skip)fault=NULL;if(!fault&&!test)return;int saved=errno;char *message=compose(pack,data,size);if(!message){errno=saved;return;}
 struct finch_trace_callback_info info={.version=1,.log=log,.subsystem=subsystem,.category=category,.format=pack?pack->format:NULL,.message=message,.pc=pack?pack->pc:NULL,.type=type&0x7f};
 if(fault)fault(&info);if(test)test(&info);free(message);errno=saved;
}
void finch_trace_quarantine(void){
 int saved=errno;
 if(finch_trace_lazy_initialized()&&os_log_type_enabled(&_os_log_default,17)){
  const uint8_t empty[2]={0};const void *image=dyld_image_header_containing_address((const void*)finch_trace_quarantine);
  _os_log_fault_impl(image,&_os_log_default,17,"QUARANTINED DUE TO HIGH LOGGING VOLUME",empty,sizeof(empty));
 }
 atomic_store_explicit(&quarantined,true,memory_order_release);errno=saved;
}
bool finch_trace_is_quarantined(void){return atomic_load_explicit(&quarantined,memory_order_acquire);}
void finch_trace_quarantine_packet(xpc_object_t packet,uint32_t state_hint_type){if(state_hint_type!=3&&finch_trace_is_quarantined())xpc_dictionary_set_bool(packet,"quarantined",true);}
