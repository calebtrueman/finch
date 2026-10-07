#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>
static unsigned checks,failures;
static void put(void *e,size_t n,uint64_t v) { memcpy((char *)e+n,&v,8); }
static void pointer(void *e,size_t n,const void *v) { put(e,n,(uintptr_t)v); }
static uint32_t random32(void) { static uint32_t s=38213; s^=s<<13;s^=s>>17;s^=s<<5;return s; }
int main(int argc,char **argv) {
 void *host=dlopen("/usr/lib/system/libsystem_trace.dylib",RTLD_NOW|RTLD_LOCAL);
 void *ours=dlopen(argc>1?argv[1]:"build/userland/trace/stream-entry-test.dylib",RTLD_NOW|RTLD_LOCAL);
 if(!host||!ours) { fprintf(stderr,"%s\n",dlerror());return 1; }
 xpc_object_t (*a)(void *,uint64_t)=dlsym(host,"_os_activity_stream_entry_encode");
 xpc_object_t (*b)(void *,uint64_t)=dlsym(ours,"_os_activity_stream_entry_encode");
 if(!a||!b) return 2;
 uint32_t types[]={0,1,0x200,0x201,0x202,0x203,0x300,0x400,0x600,0x800,0xffffffff};
 unsigned char uuid[16],data[300],private_data[100];
 for(unsigned i=0;i<sizeof data;i++)data[i]=(unsigned char)i;
 for(unsigned i=0;i<sizeof private_data;i++)private_data[i]=(unsigned char)(i^73);
 for(unsigned i=0;i<16;i++)uuid[i]=(unsigned char)(i*17);
 char path[4200],name[66000];memset(path,'p',sizeof path);path[sizeof path-1]=0;
 memset(name,'n',sizeof name);name[sizeof name-1]=0;
 xpc_object_t payload=xpc_dictionary_create(NULL,NULL,0);xpc_dictionary_set_string(payload,"sample","payload");
 for(unsigned v=1;v<=2;v++)for(unsigned t=0;t<sizeof(types)/sizeof(types[0]);t++)for(unsigned mask=0;mask<512;mask++) {
  unsigned char e[236],f[236];for(unsigned i=0;i<236;i++)e[i]=(unsigned char)random32();
  memcpy(e,&types[t],4);
  size_t pointers[]={20,28,76,84,140,148,164,180,188,212};
  for(unsigned i=0;i<10;i++)put(e,pointers[i],0);
  put(e,156,0);put(e,172,0);
  if(mask&1)pointer(e,20,uuid);
  if(mask&2)pointer(e,28,mask==511?path:"process/path");
  if(mask&4)pointer(e,76,uuid);
  if(mask&8)pointer(e,84,"image/path");
  if(mask&16)pointer(e,140,mask==511?name:"entry %d name");
  if(types[t]==0x203)e[148]=(mask&32)?1:0;
  if(types[t]==0x300||types[t]==0x400||types[t]==0x600||types[t]==0x800) {
   if(mask&32) { pointer(e,148,data); put(e,156,mask%sizeof data); }
   if(types[t]==0x300) { if(mask&64)pointer(e,164,payload); }
   else if(mask&64) { pointer(e,164,private_data);put(e,172,mask%sizeof private_data); }
  }
  if(mask&128)pointer(e,180,"subsystem");
  if(mask&256)pointer(e,188,"category");
  if(mask&64)pointer(e,212,"signpost");
  memcpy(f,e,sizeof e);
  xpc_object_t x=a(e,v),y=b(f,v);checks++;
  if(!xpc_equal(x,y)||memcmp(e,f,sizeof e)) {
   failures++;if(failures<5) { char *xx=xpc_copy_description(x),*yy=xpc_copy_description(y);fprintf(stderr,"FAIL version %u type %x mask %u\nhost %s\nours %s\n",v,types[t],mask,xx,yy);free(xx);free(yy);
    size_t nx=0,ny=0;const unsigned char *dx=xpc_dictionary_get_data(x,"entryData",&nx),*dy=xpc_dictionary_get_data(y,"entryData",&ny);if(nx==ny)for(size_t j=0;j<nx;j++)if(dx[j]!=dy[j]) {fprintf(stderr,"first byte diff %zu: %02x %02x\n",j,dx[j],dy[j]);break;}
   }
  }
  xpc_release(x);xpc_release(y);
 }
 xpc_release(payload);printf("%u stream entry checks, %u failures\n",checks,failures);return !!failures;
}
