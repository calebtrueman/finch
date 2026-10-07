/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#define sysctlbyname test_sysctlbyname
#define lstat test_lstat
#include "../storage.c"
#include <assert.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
static const char*boot;
static int boot_error,stat_error;
static mode_t file_mode;
int test_sysctlbyname(const char*name,void*out,size_t*n,void*value,size_t count){assert(!strcmp(name,"kern.bootargs")&&!value&&!count&&*n==1024);if(boot_error)return -1;strlcpy(out,boot,*n);return 0;}
int test_lstat(const char*path,struct stat*out){assert(!strcmp(path,"/private/var/db/diagnostics"));if(stat_error)return -1;memset(out,0,sizeof(*out));out->st_mode=file_mode;return 0;}
int main(void){const char*args[]={"","libtrace_full_db=0","libtrace_full_db=1","BS_VAR_DB_EXTRA=test","x libtrace_full_db=0 bs_var_db_extra=x"};unsigned tests=0;for(unsigned a=0;a<5;a++)for(unsigned error=0;error<2;error++)for(unsigned mode=0;mode<3;mode++){boot=args[a];boot_error=error;stat_error=mode==2;file_mode=mode?S_IFDIR:S_IFLNK;bool expected=error?mode==0:a==1||a==4?false:a==2||a==3?true:mode==0;pid_t child=fork();assert(child>=0);if(!child){assert(_os_trace_basesystem_storage_available()==expected);boot="libtrace_full_db=0";assert(_os_trace_basesystem_storage_available()==expected);_exit(0);}int status;assert(waitpid(child,&status,0)==child&&WIFEXITED(status)&&!WEXITSTATUS(status));tests++;}printf("Trace storage: %u boot-argument and path checks passed (mock inputs)\n",tests);}
