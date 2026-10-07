#include "../diagnostic_stream.h"
#include <dlfcn.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <ptrauth.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static uint32_t mode,generation;static xpc_object_t saved_filter,received;static unsigned opens,sends,payloads,checks;static int break_next;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"FAIL line %u: %s\n",__LINE__,#x);exit(1);}}while(0)
bool _os_trace_mode_match_4tests(uint32_t mask){return !!(mode&mask);}
uint32_t finch_trace_preferences_version(void){return generation;}
const char *_os_trace_prefsdir_path(void){return "/test-only";}
xpc_object_t _os_trace_read_plist_at(int fd,const char *path){(void)fd;CHECK(!strcmp(path,"/test-only/com.apple.diagnosticd.filter.plist"));return saved_filter?xpc_retain(saved_filter):NULL;}
void *xpc_pipe_create(const char *name,uint64_t flags){CHECK(!strcmp(name,"com.apple.diagnosticd"));CHECK(flags==2);opens++;return xpc_dictionary_create(NULL,NULL,0);}
int xpc_pipe_simpleroutine(void *pipe,xpc_object_t message){CHECK(pipe!=NULL);sends++;if(break_next){break_next--;return EPIPE;}if(received)xpc_release(received);received=xpc_copy(message);return 0;}
uint64_t voucher_get_activity_id(void *v,uint64_t *parent){CHECK(v==(void*)-3||v==(void*)71);if(parent)*parent=5678;return 1234;}
static uint64_t word(const unsigned char *p,size_t n){uint64_t v;memcpy(&v,p+n,8);return v;}
static uint32_t small(const unsigned char *p,size_t n){uint32_t v;memcpy(&v,p+n,4);return v;}
static xpc_object_t filter(const char *key,const char *text,int64_t bits){xpc_object_t d=xpc_dictionary_create(NULL,NULL,0),sub=xpc_dictionary_create(NULL,NULL,0);xpc_dictionary_set_int64(sub,text,bits);xpc_dictionary_set_value(d,key,sub);xpc_release(sub);return d;}
int main(void){
 mode=0;CHECK(!finch_trace_stream_enabled(1,0,NULL));mode=8;
 for(unsigned type=0;type<3;type++)for(unsigned k=1;k<=4;k*=2)CHECK(finch_trace_stream_enabled(k,type,NULL));
 mode=0x508;CHECK(!finch_trace_stream_enabled(4,0,NULL));mode=8;
 saved_filter=xpc_dictionary_create(NULL,NULL,0);generation++;CHECK(!finch_trace_stream_enabled(4,0,NULL));
 xpc_dictionary_set_int64(saved_filter,"global",INT64_C(0x200060000));generation++;
 CHECK(finch_trace_stream_enabled(2,2,NULL));CHECK(!finch_trace_stream_enabled(2,0,NULL));CHECK(!finch_trace_stream_enabled(1,0,NULL));
 xpc_release(saved_filter);saved_filter=NULL;generation++;
 /* Compare independent filter rules with the host's internal reader. */
 void *host=dlopen("/usr/lib/system/libsystem_trace.dylib",RTLD_NOW|RTLD_LOCAL);void *encode=dlsym(host,"_os_activity_stream_entry_encode");Dl_info info;CHECK(dladdr(encode,&info));
 bool(*match)(xpc_object_t,const struct finch_trace_filter_subject*,uint64_t*)=ptrauth_sign_unauthenticated((void*)((uintptr_t)info.dli_fbase+0x18ba0),ptrauth_key_function_pointer,0);
 struct finch_trace_filter_subject subject={"A.subsystem","Category","/Some/Path","Program",123,501};
 const char *keys[]={"subsystem","category","processImagePath","process","pid","uid"};const char *values[]={"A.subsystem","Category","/Some/Path","Program","123","501","other","", "PATH","-1"};
 for(unsigned k=0;k<6;k++)for(unsigned v=0;v<10;v++)for(unsigned bit=0;bit<32;bit++){
  xpc_object_t d=filter(keys[k],values[v],((int64_t)bit<<32)|bit);uint64_t a[2]={71,39},b[2]={71,39};bool aa=match(d,&subject,a),bb=finch_trace_filter_matches(d,&subject,b);CHECK(aa==bb&&!memcmp(a,b,sizeof a));
  for(int op=-1;op<4;op++){xpc_object_t other=filter("process","missing",0x222),children=xpc_array_create(NULL,0),expression=xpc_dictionary_create(NULL,NULL,0),outer=xpc_dictionary_create(NULL,NULL,0);xpc_array_append_value(children,d);if(op!=0)xpc_array_append_value(children,other);xpc_dictionary_set_int64(expression,"operator",op);xpc_dictionary_set_value(expression,"subfilters",children);xpc_dictionary_set_value(outer,"logicalExp",expression);a[0]=b[0]=3;a[1]=b[1]=9;aa=match(outer,&subject,a);bb=finch_trace_filter_matches(outer,&subject,b);CHECK(aa==bb&&!memcmp(a,b,sizeof a));xpc_release(other);xpc_release(children);xpc_release(expression);xpc_release(outer);}
  xpc_release(d);
 }
 unsigned char bytes[]={0x14,0x28,0x71};struct finch_trace_stream_event event={.identifier=0x100000003,.timestamp=123456,.image=_dyld_get_image_header(0),.pc=(void*)main,.name="sample",.format_offset=17,.buffer=bytes,.buffer_size=3,.activity=(void*)71};
 errno=EDOM;finch_trace_stream_send(&event,^(xpc_object_t d){payloads++;xpc_dictionary_set_int64(d,"answer",42);});CHECK(errno==EDOM);CHECK(payloads==1&&opens==1&&sends==1);CHECK(xpc_dictionary_get_uint64(received,"action")==6);CHECK(xpc_dictionary_get_uint64(received,"version")==2);CHECK(xpc_dictionary_get_int64(xpc_dictionary_get_dictionary(received,"payload"),"answer")==42);
 size_t n=0;const unsigned char *e=xpc_dictionary_get_data(received,"entryData",&n);CHECK(n>268);CHECK(small(e,0)==0x300&&small(e,4)==(unsigned)getpid());CHECK(word(e,36)==1234&&word(e,44)==5678);CHECK(word(e,52)==event.identifier&&word(e,60)==123456);CHECK(word(e,124)==17);CHECK(!strcmp((const char*)e+236+word(e,140),"sample"));CHECK(!memcmp(e+236+word(e,148),bytes,3));
 break_next=1;finch_trace_stream_send(&event,^(xpc_object_t d){(void)d;payloads++;});CHECK(opens==2&&sends==3&&payloads==2);CHECK(!xpc_dictionary_get_value(received,"payload"));
 unsigned char names[64]={0};struct finch_log_names *ln=(void*)names;ln->subsystem_size=4;ln->category_size=4;memcpy(ln->names,"sub\0cat\0",8);struct finch_log log={.names=ln};CHECK(!finch_trace_stream_enabled(8,0,&log));
 saved_filter=filter("subsystem","sub",INT64_C(0x2000c0000));generation++;log.options=UINT64_C(0x400000)<<32;
 CHECK(finch_trace_stream_enabled(8,0,&log));CHECK(finch_trace_stream_enabled(4,0,&log));CHECK(finch_trace_stream_enabled(4,1,&log));CHECK(finch_trace_stream_enabled(4,2,&log));
 log.options=0;CHECK(!finch_trace_stream_enabled(8,0,&log));log.options=UINT64_C(4)<<32;CHECK(!finch_trace_stream_enabled(4,0,&log));xpc_release(saved_filter);saved_filter=NULL;generation++;
 event.log=&log;event.identifier=0x100000006;event.private_data=bytes;event.private_size=3;event.ttl=77;event.persisted=true;event.signpost_id=928;event.signpost_name="point";
 finch_trace_stream_send(&event,NULL);e=xpc_dictionary_get_data(received,"entryData",&n);CHECK(small(e,0)==0x600&&e[200]==77&&e[201]==1);CHECK(word(e,204)==928);CHECK(!strcmp((const char*)e+236+word(e,212),"point"));CHECK(!strcmp((const char*)e+236+word(e,180),"sub"));CHECK(!strcmp((const char*)e+236+word(e,188),"cat"));CHECK(!memcmp(e+236+word(e,164),bytes,3));
 event.identifier=0x302;event.buffer=NULL;event.buffer_size=0;event.private_data=NULL;event.private_size=0;finch_trace_stream_send(&event,NULL);e=xpc_dictionary_get_data(received,"entryData",&n);CHECK(small(e,0)==0x203&&e[148]==1);
 printf("%u diagnostic stream checks passed; no host settings changed\n",checks);xpc_release(received);return 0;
}
