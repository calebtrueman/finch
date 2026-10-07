/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "format.h"
#include "blob.h"
#include <ctype.h>
#include <dirent.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
const uint8_t*os_log_fmt_extract_pubdata(const uint8_t*data,uint16_t size,const uint8_t**values,uint16_t*value_size){
 static const uint8_t empty[2]={0};*values=NULL;*value_size=0;if(!size)return empty;if(size==1)return NULL;const uint8_t*p=data+2;size_t left=size-2;for(unsigned j=0;j<data[1];j++){if(left<2||p[1]+2u>left)return NULL;size_t n=p[1]+2u;p+=n;left-=n;}*values=p;*value_size=(uint16_t)left;return data;
}
uint8_t*os_log_fmt_convert_trace(uint8_t*out,const uint8_t*data,size_t size){
 if(!size)return NULL;unsigned count=data[size-1];out[0]=0;out[1]=count;if(count>size-1)return NULL;const uint8_t*sizes=data+size-1-count,*p=data;uint8_t*q=out+2;for(unsigned j=0;j<count;j++){size_t n=sizes[j]&63;if(n>(size_t)(sizes-p))return NULL;q[0]=0;q[1]=n;memcpy(q+2,p,n);q+=n+2;p+=n;}return out;
}
struct plugin { intptr_t once;char*name;void*handle;void*format;void*state; };
struct plugin_node {struct plugin value;struct plugin_node*next;unsigned directory;};
struct cache_text {uint64_t version,address,size;unsigned char uuid[16];const char*path;uint64_t offset;};
extern bool _dyld_dlsym_blocked(void) __attribute__((weak_import));
extern bool _dyld_get_shared_cache_uuid(unsigned char*) __attribute__((weak_import));
extern int dyld_shared_cache_iterate_text(const unsigned char*,void(^)(const struct cache_text*)) __attribute__((weak_import));
extern int csr_check(uint32_t) __attribute__((weak_import));
static struct plugin_node*plugins;
static pthread_once_t plugins_once=PTHREAD_ONCE_INIT;
static pthread_mutex_t plugins_lock=PTHREAD_MUTEX_INITIALIZER;
static const char*const directories[]={"/usr/local/lib/log/","/usr/lib/log/"};
static void register_plugin(const char*file,unsigned dir){size_t n=strlen(file);if(n<13||strncmp(file,"liblog_",7)||strchr(file,'/')||strcmp(file+n-6,".dylib"))return;char*name=strndup(file+7,n-13);if(!name)return;for(struct plugin_node*p=plugins;p;p=p->next)if(!strcasecmp(p->value.name,name)){free(name);return;}struct plugin_node*p=calloc(1,sizeof(*p));if(!p){free(name);return;}p->value.name=name;p->directory=dir;p->next=plugins;plugins=p;}
static void load_plugins(void){const char*env=getenv("OS_ACTIVITY_FORMATTER");if(env&&!strcmp(env,"disable"))return;bool local=csr_check&&csr_check(16)==0;for(unsigned j=0;j<2;j++){if(!j&&!local)continue;DIR*d=opendir(directories[j]);if(d){struct dirent*e;while((e=readdir(d)))if(e->d_type==DT_REG)register_plugin(e->d_name,j);closedir(d);}}
 unsigned char uuid[16];if(_dyld_get_shared_cache_uuid&&dyld_shared_cache_iterate_text&&_dyld_get_shared_cache_uuid(uuid))dyld_shared_cache_iterate_text(uuid,^(const struct cache_text*t){if(!t->path)return;for(unsigned j=0;j<2;j++){if(!j&&!local)continue;size_t n=strlen(directories[j]);if(!strncmp(t->path,directories[j],n))register_plugin(t->path+n,j);}});
}
struct plugin*os_log_fmt_get_plugin(const char*name,size_t n){if(_dyld_dlsym_blocked&&_dyld_dlsym_blocked())return NULL;pthread_once(&plugins_once,load_plugins);pthread_mutex_lock(&plugins_lock);struct plugin*out=NULL;for(struct plugin_node*p=plugins;p;p=p->next)if(strlen(p->value.name)==n&&!strncasecmp(name,p->value.name,n)){out=&p->value;if(out->once!=-1){char path[1024];snprintf(path,sizeof(path),"%sliblog_%s.dylib",directories[p->directory],out->name);out->handle=dlopen(path,RTLD_NOW|RTLD_LOCAL);if(out->handle){out->format=dlsym(out->handle,"OSLogCopyFormattedString");out->state=dlsym(out->handle,"OSStateCreateStringWithData");}out->once=-1;}break;}pthread_mutex_unlock(&plugins_lock);return out;}
/* Privacy comes from each saved record. An annotation in the format string
 * describes how it was captured, not whether its saved value is available. */
static char*without_privacy(const char*format){size_t n=strlen(format);char*out=malloc(n+1);if(!out)return NULL;size_t at=0;for(size_t j=0;j<n;){if(format[j]=='%'&&format[j+1]=='{'){out[at++]=format[j++];out[at++]=format[j++];bool first=true;while(j<n&&format[j]!='}'){while(format[j]==' '||format[j]==',')j++;size_t begin=j;while(j<n&&format[j]!=','&&format[j]!='}')j++;size_t end=j;while(end>begin&&format[end-1]==' ')end--;size_t z=end-begin;bool skip=(z==7&&!memcmp(format+begin,"private",7))||(z==9&&!memcmp(format+begin,"sensitive",9));if(z&&!skip){if(!first)out[at++]=',';memcpy(out+at,format+begin,z);at+=z;first=false;}}}else out[at++]=format[j++];}out[at]=0;return out;}

static void append_utf8(struct finch_trace_blob*b,const char*s,size_t n){uint32_t before=b->length;size_t used=os_trace_blob_add_slow(b,s,n);if(used<n&&used){size_t lead=used;while(lead&&(s[lead]&0xc0)==0x80)lead--;if(lead<used){b->length=before+(uint32_t)lead;if(!b->binary)((char*)b->data)[b->length]=0;}}}
struct saved_record {unsigned tag,size;const uint8_t*bytes;};
struct saved_cursor {const uint8_t*p;unsigned left;};
static bool take_record(struct saved_cursor*c,struct saved_record*r){if(!c->left)return false;r->tag=c->p[0];r->size=c->p[1];r->bytes=c->p+2;c->p+=2+r->size;c->left--;return true;}
struct conversion {size_t n,precision_start,precision_end;bool width_star,precision_star,has_precision,cant;unsigned precision;char kind,length,second;};
static struct conversion conversion(const char*f,uintptr_t mode){struct conversion c={0};const char*p=f+1;if(*p=='{'){if((mode&~(uintptr_t)4)!=2)return c;const char*end=strchr(p,'}');if(!end)return c;p=end+1;}while(*p&&strchr("-+ #0'",*p))p++;if(*p=='*'){c.width_star=true;p++;}else while(isdigit((unsigned char)*p))p++;if(*p=='$'){c.cant=true;p++;}if(*p=='.'){c.has_precision=true;c.precision_start=(size_t)(p-f);p++;if(*p=='*'){c.precision_star=true;p++;}else while(isdigit((unsigned char)*p)){if(c.precision<65536)c.precision=c.precision*10+*p-'0';p++;}c.precision_end=(size_t)(p-f);}if(*p&&strchr("hljztLq",*p)){c.length=*p++;if((*p=='h'&&c.length=='h')||(*p=='l'&&c.length=='l'))c.second=*p++;}if(!*p||!strchr("diouxXDOUfFeEgGaAcCsSp@Pmn",*p)||(*p=='P'&&mode!=2))return (struct conversion){0};c.kind=*p++;c.n=(size_t)(p-f);return c;}
static void mismatch(struct finch_trace_blob*b,const char*f,size_t n,const struct saved_record*r,unsigned size){static const char*names[]={"SCALAR","COUNT","STRING","DATA","OBJECT"};char numeric[16];snprintf(numeric,sizeof(numeric),"%u",r->tag>>4);os_trace_blob_addf(b,"<decode: mismatch for [%.*s] got [%s%s%s sz:%u]>",(int)n,f,r->tag<0x50?names[r->tag>>4]:numeric,r->tag&2?" public":"",r->tag&1?" private":"",size);}
static void native_record(uint8_t*out,size_t*length,unsigned tag,unsigned n,const void*p){out[(*length)++]=tag;out[(*length)++]=n;if(n)memcpy(out+*length,p,n);*length+=n;out[1]++;}
void os_log_fmt_compose(struct finch_trace_blob*blob,const char*format,uintptr_t mode,unsigned privacy,unsigned pointer_size,const uint8_t*records,const uint8_t*public_data,uint16_t public_size,const uint8_t*private_data,uint16_t private_size){
 static const uint8_t empty[2]={0};if(!records)records=empty;if(!format)format="";struct saved_cursor cursor={records+2,records[1]};unsigned level=(records[0]>>5)&3;static const unsigned grade[8]={1,2,1,0,0,3,0,0};
 for(const char*f=format;*f;){if(*f!='%'){size_t n=strcspn(f,"%");finch_trace_blob_append(blob,f,n);f+=n;continue;}struct conversion cv=conversion(f,mode);if(!cv.n){if(!f[1])break;finch_trace_blob_append(blob,f+1,1);f+=2;continue;}const char*start=f;f+=cv.n;if(cv.cant||cv.kind=='n'||(cv.kind=='P'&&!cv.has_precision)){os_trace_blob_addf(blob,"<decode: can't compose [%.*s]>",(int)cv.n,start);return;}
  uint8_t native[1024]={0};size_t nn=2;int width=0,precision=-1;struct saved_record r={0};if(cv.width_star){if(take_record(&cursor,&r)&&r.size==4&&(r.tag>>4)<=1)memcpy(&width,r.bytes,4);native_record(native,&nn,0,4,&width);}if(cv.precision_star){if(take_record(&cursor,&r)&&r.size==4&&(r.tag>>4)<=1)memcpy(&precision,r.bytes,4);native_record(native,&nn,0,4,&precision);}if(cv.has_precision&&!cv.precision_star&&strchr("sSP@",cv.kind) ){take_record(&cursor,&r);}
  if(!take_record(&cursor,&r)){finch_trace_blob_append(blob,"<decode: missing data>",22);continue;}unsigned type=r.tag>>4;if(type==1){mismatch(blob,start,cv.n,&r,0);continue;}bool hidden=false;if(r.tag&1){unsigned g=grade[r.tag&7];if((r.tag&3)==3){mismatch(blob,start,cv.n,&r,0);continue;}hidden=g>privacy||((level>0&&level<g)&&r.tag<0x90)||(!level&&!private_data);}
  if(hidden){finch_trace_blob_append(blob,"<private>",9);continue;}const uint8_t*value=r.bytes;unsigned size=r.size;bool truncated=false;uint16_t off=0,encoded_size=0;
  if((r.tag&0xf1)!=0&&(r.tag&0xe1)!=0){if(r.size!=4){mismatch(blob,start,cv.n,&r,0);continue;}memcpy(&off,r.bytes,2);memcpy(&encoded_size,r.bytes+2,2);size=encoded_size&0x7fff;truncated=encoded_size>>15;const uint8_t*data=(r.tag&1)?private_data:public_data;unsigned bound=(r.tag&1)?private_size:public_size;
   if(off>bound||size>bound-off||(bound&&!data)){os_trace_blob_addf(blob,"<decode: bad range for [%.*s] got [offs:%u len:%u within:0]>",(int)cv.n,start,off,size);continue;}value=data?data+off:NULL;if(!data&&bound==0&&!(r.tag&1))value=NULL;if(type==0&&truncated){finch_trace_blob_append(blob,"<decode: missing data>",22);continue;}
  }
  if(type==0&&!size){finch_trace_blob_append(blob,"<decode: missing data>",22);continue;}bool scalar_kind=strchr("diouxXDOUfFeEgGaAcCpmn",cv.kind)!=NULL;bool valid=true;
  if(scalar_kind){valid=type==0&&size&&!(size&(size-1));unsigned max=4;if(cv.length=='l'&&!cv.second)max=pointer_size;else if(cv.second=='l'||strchr("jztq",cv.length?cv.length:'!'))max=8;if(strchr("DOU",cv.kind))max=pointer_size;if(cv.kind=='p')valid=valid&&size==pointer_size;else if(strchr("fFeEgGaA",cv.kind))valid=valid&&size==8;else valid=valid&&size<=max;
  }else if(cv.kind=='s'||cv.kind=='S')valid=type==((cv.kind=='S'||cv.length=='l')?5:2);else if(cv.kind=='@')valid=type==4;else if(cv.kind=='P')valid=type==3;else valid=false;
  if(!valid){mismatch(blob,start,cv.n,&r,size);continue;}
  char*spec=strndup(start,cv.n);char*clean=spec?without_privacy(spec):NULL;free(spec);if(!clean)continue;if(type==3&&!strstr(clean,"uuid_t")){static const char digits[]="0123456789ABCDEF";finch_trace_blob_append(blob,"'",1);for(unsigned j=0;j<size;j++){char hex[3]={' ',digits[value[j]>>4],digits[value[j]&15]};finch_trace_blob_append(blob,hex+(j?0:1),j?3:2);}if(truncated)append_utf8(blob,"…'",4);else finch_trace_blob_append(blob,"'",1);free(clean);continue;}char*owned=NULL;uint64_t pointer=0;
  if(!scalar_kind){if((size&&value)||truncated){owned=malloc((size_t)size+1);if(!owned){free(clean);continue;}memcpy(owned,value,size);owned[size]=0;pointer=(uintptr_t)owned;}native_record(native,&nn,(type<<4)|2,8,&pointer);
   if(cv.kind=='P'){char*dot=strrchr(clean,'.');if(dot){char*end=dot+1;if(*end=='*'){precision=(int)size;size_t where=2+(cv.width_star?6:0)+2;memcpy(native+where,&precision,4);}else{size_t offset=(size_t)(dot-clean);char*replacement=malloc(offset+32);if(replacement){snprintf(replacement,offset+32,"%.*s.%uP",(int)offset,clean,size);free(clean);clean=replacement;}}}}
   else if(cv.has_precision&&!cv.precision_star){char*dot=strrchr(clean,'.');if(dot){size_t offset=(size_t)(dot-clean);char*replacement=malloc(offset+32);if(replacement){snprintf(replacement,offset+32,"%.*s%s%u%c",(int)offset,clean,size?".":"",size?size:0,cv.kind);if(!size)snprintf(replacement,offset+32,"%.*s%c",(int)offset,clean,cv.kind);free(clean);clean=replacement;}}}
   else if(cv.precision_star){if(!size)precision=INT32_MAX;else if(precision<0||(unsigned)precision>size)precision=(int)size;size_t where=2+(cv.width_star?6:0)+2;memcpy(native+where,&precision,4);}
  }else native_record(native,&nn,0,size,value);
  char*text=finch_log_compose_saved(clean,native,nn);if(text){finch_trace_blob_append(blob,text,strlen(text));free(text);}if(truncated&&type>=2)append_utf8(blob,"<…>",5);free(owned);free(clean);
 }
 while(blob->length&&isspace(((unsigned char*)blob->data)[blob->length-1]))blob->length--;if(!blob->binary&&blob->data)((char*)blob->data)[blob->length]=0;
}
