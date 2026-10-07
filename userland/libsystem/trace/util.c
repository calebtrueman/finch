/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "internal.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/uio.h>
#include <sys/xattr.h>
#include <unistd.h>
/* Allocation failure is retried: these SPI callers do not handle NULL. */
static void shortage(void){struct timespec t={1,0};nanosleep(&t,NULL);}
API void *_os_trace_malloc_typed(size_t n,uint64_t type){(void)type;void*p;while(!(p=malloc(n)))shortage();return p;}
API void *_os_trace_calloc_typed(size_t n,size_t size,uint64_t type){(void)type;void*p;while(!(p=calloc(n,size)))shortage();return p;}
API void *_os_trace_zalloc_typed(size_t n,uint64_t type){return _os_trace_calloc_typed(1,n,type);}
API void *_os_trace_realloc_typed(void*old,size_t n,uint64_t type){(void)type;void*p;while(!(p=realloc(old,n)))shortage();return p;}
API char *_os_trace_strdup(const char*s){char*p;while(!(p=strdup(s)))shortage();return p;}
API void *_os_trace_memdup(const void*s,size_t n){void*p=_os_trace_malloc_typed(n,0);memcpy(p,s,n);return p;}
static ssize_t undo(int fd,size_t n,int error){off_t off=lseek(fd,-(off_t)n,SEEK_CUR);if(off!=-1)ftruncate(fd,off);errno=error;return -1;}
API ssize_t _os_trace_write(int fd,const void*data,size_t n){size_t done=0;while(done<n){ssize_t r=write(fd,(const char*)data+done,n-done);if(r>0)done+=(size_t)r;else if(r<0&&errno!=EINTR)return undo(fd,done,errno);else if(!r)return undo(fd,done,EIO);}return (ssize_t)done;}
API ssize_t _os_trace_writev(int fd,const struct iovec*iov,size_t count){
 if(!count)return 0;if(count>SIZE_MAX/sizeof(*iov)){errno=EINVAL;return -1;}
 struct iovec*copy=malloc(count*sizeof(*copy));if(!copy)return -1;memcpy(copy,iov,count*sizeof(*copy));size_t done=0,index=0;
 while(index<count){size_t batch=count-index;if(batch>1024)batch=1024;ssize_t n=writev(fd,copy+index,(int)batch);
  if(n<0){if(errno==EINTR)continue;int err=errno;free(copy);return undo(fd,done,err);}
  size_t consumed=(size_t)n;done+=consumed;
  while(index<count&&consumed>=copy[index].iov_len){consumed-=copy[index].iov_len;index++;}
  if(index<count){copy[index].iov_base=(char*)copy[index].iov_base+consumed;copy[index].iov_len-=consumed;if(!n){free(copy);return undo(fd,done,EIO);}}
 }
 free(copy);return (ssize_t)done;
}
API void *_os_trace_mmap_offset(int fd,size_t n,off_t offset){void*p=mmap(NULL,n,PROT_READ,MAP_PRIVATE|MAP_RESILIENT_CODESIGN,fd,offset);return p==MAP_FAILED?NULL:p;}
API void *_os_trace_mmap(int fd,size_t*length){off_t end=lseek(fd,0,SEEK_END);if(end<=0){if(!end)errno=ERANGE;*length=0;return NULL;}void*p=_os_trace_mmap_offset(fd,(size_t)end,0);*length=p?(size_t)end:0;return p;}
API void *_os_trace_mmap_at(int dir,const char*path,int flags,size_t*length){int fd=openat(dir,path,flags|O_NONBLOCK|O_CLOEXEC);if(fd<0){*length=0;return NULL;}void*p=_os_trace_mmap(fd,length);int err=errno;close(fd);errno=err;return p;}
API void *_os_trace_read_file_at(int dir,const char*path,size_t limit,size_t*length){
 *length=0;int fd=openat(dir,path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return NULL;off_t end=lseek(fd,0,SEEK_END);int err=errno;if(end<0)goto failed;if((uint64_t)end>limit){err=ERANGE;goto failed;}
 void*p=_os_trace_malloc_typed((size_t)end,0);size_t done=0;while(done<(size_t)end){ssize_t n=pread(fd,(char*)p+done,(size_t)end-done,(off_t)done);if(n>0)done+=(size_t)n;else if(n<0&&errno==EINTR)continue;else{err=n==0?ESTALE:errno;free(p);goto failed;}}
 close(fd);*length=(size_t)end;return p;
 failed:close(fd);errno=err;return NULL;
}
API ssize_t _os_trace_getxattr_at(int dir,const char*path,int flags,const char*name,void*out,size_t n){int fd=openat(dir,path,flags|O_NONBLOCK|O_CLOEXEC);if(fd<0)return -1;ssize_t ret=fgetxattr(fd,name,out,n,0,0);int err=errno;close(fd);errno=err;return ret;}
API void _os_trace_scandir_free_namelist(int count,struct dirent**names){for(int i=0;i<count;i++)free(names[i]);free(names);}
API int _os_trace_fdscandir_b(int fd,struct dirent***out,int(^filter)(const struct dirent*),int(^compare)(const void*,const void*)){
 *out=NULL;int copy=dup(fd);if(copy<0)return -1;lseek(copy,0,SEEK_SET);DIR*d=fdopendir(copy);if(!d){int err=errno;close(copy);errno=err;return -1;}
 size_t count=0,cap=32;struct dirent**names=_os_trace_malloc_typed(cap*sizeof(*names),0);rewinddir(d);struct dirent*e;
 while((e=readdir(d))){if(filter&&!filter(e))continue;if(count==cap){cap*=2;struct dirent**p=realloc(names,cap*sizeof(*names));if(!p){closedir(d);_os_trace_scandir_free_namelist((int)count,names);return -1;}names=p;}size_t n=offsetof(struct dirent,d_name)+e->d_namlen+1;names[count++]=_os_trace_memdup(e,n);}
 closedir(d);if(compare&&count)qsort_b(names,count,sizeof(*names),compare);*out=names;return (int)count;
}
static char boot_uuid[37];static pthread_once_t boot_once=PTHREAD_ONCE_INIT;
static void read_boot(void){size_t n=sizeof(boot_uuid);if(sysctlbyname("kern.bootsessionuuid",boot_uuid,&n,NULL,0))abort();}
API const char *_os_trace_get_boot_uuid(void){pthread_once(&boot_once,read_boot);return boot_uuid;}
extern int mach_get_times(uint64_t*,uint64_t*,struct timespec*);
API void _os_trace_get_times_now(uint64_t*continuous,uint64_t*wall,int*zone){struct timespec now={0};mach_get_times(NULL,continuous,&now);*wall=(uint64_t)now.tv_sec*1000000000+(uint64_t)now.tv_nsec;if(zone){struct tm t;localtime_r(&now.tv_sec,&t);zone[0]=(int)(-t.tm_gmtoff/60)+t.tm_isdst*60;zone[1]=t.tm_isdst;}}
API const char *_os_trace_sysprefsdir_path(void){return "/System/Library/Preferences/Logging";}
API const char *_os_trace_prefsdir_path(void){return "/Library/Preferences/Logging";}
API const char *_os_trace_intprefsdir_path(void){return "/AppleInternal/Library/Preferences/Logging";}
API const char *_os_trace_os_cryptex_sysprefsdir_path(void){return "/System/Cryptexes/OS/System/Library/Preferences/Logging";}
API const char *_os_trace_app_cryptex_sysprefsdir_path(void){return "/System/Cryptexes/App/System/Library/Preferences/Logging";}
extern void _simple_asl_log(int,const char*,const char*);
API void _os_trace_log_simple(const char*format,...){va_list ap;va_start(ap,format);char*p=NULL;vasprintf(&p,format,ap);va_end(ap);if(p){_simple_asl_log(5,"com.apple.trace",p);free(p);}}

API const char _os_trace_sect_names[3][16]={"__cstring","__oslogstring","__asan_cstring"};
