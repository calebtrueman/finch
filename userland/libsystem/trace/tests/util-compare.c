/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <dlfcn.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/uio.h>
struct api {void*(*malloc)(size_t,uint64_t);void*(*calloc)(size_t,size_t,uint64_t);void*(*realloc)(void*,size_t,uint64_t);void*(*memdup)(const void*,size_t);char*(*strdup)(const char*);ssize_t(*write)(int,const void*,size_t);ssize_t(*writev)(int,const struct iovec*,size_t);void*(*read)(int,const char*,size_t,size_t*);void*(*mmap)(int,size_t*);void*(*mmap_at)(int,const char*,int,size_t*);int(*scan)(int,struct dirent***,int(^)(const struct dirent*),int(^)(const void*,const void*));void(*free_names)(int,struct dirent**);void(*times)(uint64_t*,uint64_t*,int*);};
static unsigned checks,failed;
#define C(X) do{checks++;if(!(X)){if(failed++<20)fprintf(stderr,"line %d: %s\n",__LINE__,#X);}}while(0)
static void bind(struct api*a,void*h){
#define B(F,S) do{*(void**)(&a->F)=dlsym(h,S);if(!a->F)exit(2);}while(0)
 B(malloc,"_os_trace_malloc_typed");B(calloc,"_os_trace_calloc_typed");B(realloc,"_os_trace_realloc_typed");B(memdup,"_os_trace_memdup");B(strdup,"_os_trace_strdup");B(write,"_os_trace_write");B(writev,"_os_trace_writev");B(read,"_os_trace_read_file_at");B(mmap,"_os_trace_mmap");B(mmap_at,"_os_trace_mmap_at");B(scan,"_os_trace_fdscandir_b");B(free_names,"_os_trace_scandir_free_namelist");B(times,"_os_trace_get_times_now");
}
int main(int argc,char**argv){if(argc!=2)return 2;struct api a[2];bind(a,dlopen("/usr/lib/system/libsystem_trace.dylib",2));bind(a+1,dlopen(argv[1],2));char path[]="/tmp/finch-trace-test-XXXXXX";char*dir=mkdtemp(path);if(!dir)return 2;int dfd=open(dir,O_RDONLY);int fd=openat(dfd,"data",O_CREAT|O_RDWR,0600);unsigned char bytes[2048];for(size_t i=0;i<sizeof(bytes);i++)bytes[i]=(unsigned char)i;
 for(int k=0;k<2;k++)for(size_t n=0;n<=1024;n+=16){void*p=a[k].calloc(n,1,0);C(p!=NULL);for(size_t i=0;i<n;i++)C(((uint8_t*)p)[i]==0);p=a[k].realloc(p,n+3,0);C(p!=NULL);free(p);p=a[k].memdup(bytes,n);C(!memcmp(p,bytes,n));free(p);}
 for(size_t len=0;len<=128;len++){
  ftruncate(fd,0);lseek(fd,0,SEEK_SET);C(a[0].write(fd,bytes,len)==(ssize_t)len);
  for(size_t limit=0;limit<=130;limit+=13){size_t n[2]={99,99};int e[2];void*p[2];for(int k=0;k<2;k++){errno=0;p[k]=a[k].read(dfd,"data",limit,n+k);e[k]=errno;}C(n[0]==n[1]);C(e[0]==e[1]);C((p[0]!=NULL)==(p[1]!=NULL));if(p[0]&&p[1])C(!memcmp(p[0],p[1],n[0]));free(p[0]);free(p[1]);}
  size_t n[2]={99,99};int e[2];void*p[2];for(int k=0;k<2;k++){errno=0;p[k]=a[k].mmap_at(dfd,"data",0,n+k);e[k]=errno;}C(n[0]==n[1]);C(e[0]==e[1]);C((p[0]!=NULL)==(p[1]!=NULL));for(int k=0;k<2;k++)if(p[k]){C(!memcmp(p[k],bytes,len));munmap(p[k],n[k]);}
 }
 for(int k=0;k<2;k++){ftruncate(fd,0);lseek(fd,0,SEEK_SET);struct iovec v[3]={{bytes,16},{bytes+16,0},{bytes+16,32}};C(a[k].writev(fd,v,3)==48);unsigned char buf[48];C(pread(fd,buf,48,0)==48);C(!memcmp(buf,bytes,48));errno=0;C(a[k].write(-1,bytes,1)==-1);C(errno==EBADF);}
 struct dirent**names[2];int n[2];for(int k=0;k<2;k++)n[k]=a[k].scan(dfd,names+k,^int(const struct dirent*d){return d->d_name[0]!='.';},^int(const void*x,const void*y){return strcmp((*(struct dirent*const*)x)->d_name,(*(struct dirent*const*)y)->d_name);});C(n[0]==n[1]);for(int i=0;i<n[0];i++)C(!strcmp(names[0][i]->d_name,names[1][i]->d_name));for(int k=0;k<2;k++)a[k].free_names(n[k],names[k]);
 uint64_t ticks[2],wall[2];int tz[2][2];for(int k=0;k<2;k++)a[k].times(ticks+k,wall+k,tz[k]);C(ticks[1]>=ticks[0]);C(wall[1]>=wall[0]);C(wall[1]-wall[0]<1000000000);C(!memcmp(tz[0],tz[1],sizeof(tz[0])));
 close(fd);unlinkat(dfd,"data",0);close(dfd);rmdir(dir);printf("trace helpers: %u checks, %u failures\n",checks,failed);return failed?1:0;
}
