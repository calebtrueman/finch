/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Independently derived from the public entry points and host comparisons. */
#include "internal.h"
#include "blob.h"
#include <execinfo.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <uuid/uuid.h>
struct trace_frame {uuid_t uuid;uint32_t offset;};
struct trace_backtrace {struct trace_frame *frames;int count;};
extern int backtrace_from_fp(void *,void **,int);
extern int thread_stack_async_pcs(uintptr_t *,unsigned,unsigned *);
API void os_log_backtrace_destroy(struct trace_backtrace*b){if(b){free(b->frames);free(b);}}
API struct trace_frame *os_log_backtrace_get_frames(struct trace_backtrace*b){return b->frames;}
API int os_log_backtrace_get_length(struct trace_backtrace*b){return b->count;}
API struct trace_backtrace *os_log_backtrace_create_from_pcs(void *const *pcs,int count){
 if(count<0)return NULL;
 struct trace_backtrace*b=calloc(1,sizeof(*b));if(!b)return NULL;
 b->frames=calloc(count?count:1,sizeof(*b->frames));if(!b->frames){free(b);return NULL;}
 b->count=count;if(count)backtrace_image_offsets(pcs,(struct image_offset *)b->frames,count);return b;
}
API struct trace_backtrace *os_log_backtrace_create_from_current(unsigned max,void *fp){
 if(max>INT32_MAX)return NULL;void **pcs=calloc(max?max:1,sizeof(*pcs));if(!pcs)return NULL;
 int n=max?(fp?backtrace_from_fp(fp,pcs,max):backtrace(pcs,max)):0;
 struct trace_backtrace*b=os_log_backtrace_create_from_pcs(pcs,n);free(pcs);return b;
}
API struct trace_backtrace *os_log_backtrace_create_from_return_address(unsigned max,void *address){
 if(max>INT32_MAX)return NULL;void **pcs=calloc(max?max:1,sizeof(*pcs));if(!pcs)return NULL;
 unsigned n=0;if(max)thread_stack_async_pcs((uintptr_t*)pcs,max,&n);while(n&&!pcs[n-1])n--;
 unsigned start=n?1:0;for(unsigned i=0;i<n;i++)if(pcs[i]==address){start=i;break;}
 struct trace_backtrace*b=os_log_backtrace_create_from_pcs(pcs+start,n-start);free(pcs);return b;
}
static void *serialize_buffer(struct trace_backtrace*b,size_t *size){
 if(b->count<0||b->count>UINT16_MAX)return NULL;
 unsigned n=b->count,u=0;uuid_t table[255];uint8_t *indices=malloc(n?n:1);if(!indices)return NULL;
 for(unsigned i=0;i<n;i++){
  unsigned j=0;if(uuid_is_null(b->frames[i].uuid)){indices[i]=255;continue;}
  while(j<u&&uuid_compare(table[j],b->frames[i].uuid))j++;
  if(j==u&&u<255){uuid_copy(table[u],b->frames[i].uuid);u++;}
  indices[i]=j<255?j:255;
 }
 size_t len=4+16*u+4*n+((n+3)&~3u);uint8_t *out=calloc(1,len);if(!out){free(indices);return NULL;}
 out[0]=0x12;out[1]=u;uint16_t count=n;memcpy(out+2,&count,2);
 for(unsigned j=0;j<u;j++)memcpy(out+4+16*j,table[u-1-j],16);
 for(unsigned i=0;i<n;i++){
  memcpy(out+4+16*u+4*i,&b->frames[i].offset,4);
  out[4+16*u+4*n+i]=indices[i]==255?255:u-1-indices[i];
 }
 free(indices);if(size)*size=len;return out;
}
API void *os_log_backtrace_copy_serialized_buffer(struct trace_backtrace*b,size_t*size){size_t n;void*p=serialize_buffer(b,&n);if(p&&size)*size=n>4096?4096:n;return p;}
API void os_log_backtrace_serialize_to_blob(struct trace_backtrace*b,void*blob){
 size_t n=0;uint8_t*p=serialize_buffer(b,&n);if(!p)return;
 unsigned count=b->count,table=16*p[1];finch_trace_blob_append(blob,p,4);finch_trace_blob_append(blob,p+4,table);
 for(unsigned i=0;i<count;i++)finch_trace_blob_append(blob,p+4+table+4*i,4);
 for(unsigned i=0;i<count;i++)finch_trace_blob_append(blob,p+4+table+4*count+i,1);
 if(count%4)finch_trace_blob_append(blob,p+n-(4-count%4),4-count%4);free(p);
}
API struct trace_backtrace *os_log_backtrace_create_from_buffer(const void **data,size_t *remaining){
 const uint8_t*p=*data;if(*remaining<4||p[0]!=0x12)return NULL;
 unsigned u=p[1];uint16_t n;memcpy(&n,p+2,2);size_t len=4+16*u+4*n+((n+3u)&~3u);if(len>*remaining)return NULL;
 const uint8_t*offsets=p+4+16*u,*indices=offsets+4*n;
 for(unsigned i=0;i<n;i++)if(indices[i]!=255&&indices[i]>=u)return NULL;
 struct trace_backtrace*b=calloc(1,sizeof(*b));if(!b)return NULL;
 b->frames=calloc(n?n:1,sizeof(*b->frames));if(!b->frames){free(b);return NULL;}b->count=n;
 for(unsigned i=0;i<n;i++){if(indices[i]!=255)memcpy(b->frames[i].uuid,p+4+16*indices[i],16);memcpy(&b->frames[i].offset,offsets+4*i,4);}
 *data=p+len;*remaining-=len;return b;
}
API char *os_log_backtrace_copy_description(struct trace_backtrace*b){
 size_t capacity=(size_t)b->count*52+1;char*out=calloc(1,capacity);if(!out)return NULL;size_t len=0;
 for(int i=0;i<b->count;i++){char uuid[37];uuid_unparse_upper(b->frames[i].uuid,uuid);len+=snprintf(out+len,capacity-len,"%s +0x%x\n",uuid,b->frames[i].offset);}if(len>4095)out[4095]=0;return out;
}
API void os_log_backtrace_print_to_blob(struct trace_backtrace*b,void*blob){for(int i=0;i<b->count;i++){char uuid[37];uuid_unparse_upper(b->frames[i].uuid,uuid);os_trace_blob_addf(blob,"%s +0x%x\n",uuid,b->frames[i].offset);}}
