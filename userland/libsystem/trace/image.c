/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Mach-O image ranges observed through the host trace interface. */
#include "image.h"
#include <stdbool.h>
#include <string.h>
extern bool _dyld_is_memory_immutable(const void*,size_t) __attribute__((weak_import));
static uint32_t u32(const void*p){uint32_t n;memcpy(&n,p,4);return n;}
static uint64_t u64(const void*p){uint64_t n;memcpy(&n,p,8);return n;}
static int name(const unsigned char*p,const char*s){return strncmp((const char*)p,s,16)==0;}
int _os_trace_macho_for_each_slice(const void*image,size_t size,int(^callback)(const void*,size_t)){
 if(size<4)return 88;const unsigned char*p=image;uint32_t magic=u32(p);
 if(magic==0xfeedface||magic==0xcefaedfe||magic==0xfeedfacf||magic==0xcffaedfe){if(size<(magic==0xfeedface||magic==0xcefaedfe?28:32))return 88;return callback(image,size);}
 if(magic!=0xcafebabe&&magic!=0xbebafeca)return 88;if(size<8)return 88;bool swap=magic==0xbebafeca;uint32_t count=u32(p+4);if(swap)count=__builtin_bswap32(count);uint64_t table=(uint64_t)count*20;if(table>UINT32_MAX||table>size-8)return 88;
 for(uint32_t j=0;j<count;j++){const unsigned char*a=p+8+20*(size_t)j;uint32_t off=u32(a+8),n=u32(a+12);if(swap){off=__builtin_bswap32(off);n=__builtin_bswap32(n);}if(off>size||n>size-off)return 88;int rc=callback(p+off,n);if(rc)return rc;}return 0;
}
static void section(struct finch_trace_image_info*info,const unsigned char*p,uint32_t off,uint32_t address,uint32_t size,struct finch_trace_image_range*constant){
 static const char names[5][16]={"__cstring","__oslogstring","__asan_cstring","__ctf","__string"};struct finch_trace_image_range r={off,size,address};for(unsigned j=0;j<5;j++)if(!memcmp(p,names[j],16)){info->ranges[j]=r;return;}static const char cname[16]="__const";if(!memcmp(p,cname,16))*constant=r;
}
size_t _os_trace_get_image_info(const void*image,size_t size,unsigned char*uuid,struct finch_trace_image_info*info,unsigned flags){
 const unsigned char*p=image;bool mapped=flags&1,have_uuid=false,asan=false;size_t image_size=0;int error=88;struct finch_trace_image_range constant={0};if(info){memset(info,0,sizeof(*info));info->mutable_image=!(_dyld_is_memory_immutable&&_dyld_is_memory_immutable(image,28));}
 if(!mapped&&size<4)goto finish;uint32_t magic=u32(p);bool wide=magic==0xfeedfacf;size_t header=wide?32:28;if(magic!=0xfeedface&&!wide)goto finish;if(!mapped&&(size<header||u32(p+20)>size-header))goto finish;uint32_t count=u32(p+16);size_t left=u32(p+20);p+=header;error=0;
 for(uint32_t j=0;j<count;j++){
  if(left<8){error=88;break;}uint32_t cmd=u32(p),n=u32(p+4);if(n>left){error=88;break;}left-=n;
  if(cmd==1||cmd==25){size_t fixed=cmd==25?72:56,ss=cmd==25?80:68;if(n<fixed||(cmd==25)!=wide){error=88;break;}
   if(name(p+8,"__TEXT")||name(p+8,"__CTF")||name(p+8,"__OS_LOG")){image_size=wide?u64(p+48):u32(p+36);if(info){if(u32(p+(wide?68:52))&8)info->encrypted=1;uint32_t ns=u32(p+(wide?64:48));if(ns>(n-fixed)/ss){error=88;break;}const unsigned char*s=p+fixed;for(uint32_t k=0;k<ns;k++,s+=ss){uint64_t sz=wide?u64(s+40):u32(s+36);if(sz>UINT32_MAX){error=34;break;}section(info,s,u32(s+(wide?48:40)),u32(s+32)-u32(p+24),(uint32_t)sz,&constant);}if(error)break;}}
  }else if(cmd==27){if(n<24){error=88;break;}if(uuid)memcpy(uuid,p+8,16);if(info)info->uuid=p+8;have_uuid=true;
  }else if(cmd==12){if(n<24){error=88;break;}uint32_t off=u32(p+8);if(off>=n){error=88;break;}if(info&&n-off>=24&&!memcmp(p+off,"@rpath/libclang_rt.asan",23))asan=true;
  }else if(cmd==33||cmd==44){if((cmd==33&&(wide||n<20))||(cmd==44&&(!wide||n<24))){error=88;break;}if(info&&u32(p+16))info->encrypted=1;}
  if(!info&&have_uuid&&image_size)break;p+=n;
 }
finish:
 if(info){if(asan&&!info->ranges[2].offset)info->ranges[2]=constant;if(!mapped)for(unsigned j=0;j<5;j++)if(info->ranges[j].size&&(info->ranges[j].offset>size||info->ranges[j].size>size-info->ranges[j].offset))return 0;}
 if(error||!have_uuid||!image_size){if(uuid)memset(uuid,0,16);return 0;}return image_size;
}
