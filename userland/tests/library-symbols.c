/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Check every expected symbol, including data, belongs to the tested file. */
#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char**argv){
 if(argc!=3){fprintf(stderr,"usage: library-symbols dylib exports.txt\n");return 2;}
 char expected[PATH_MAX];if(!realpath(argv[1],expected)){perror(argv[1]);return 2;}
 void*library=dlopen(expected,RTLD_NOW|RTLD_LOCAL);if(!library){fprintf(stderr,"%s\n",dlerror());return 2;}
 FILE*names=fopen(argv[2],"r");if(!names){perror(argv[2]);return 2;}
 char name[512],actual[PATH_MAX];unsigned total=0,failed=0;
 while(fscanf(names,"%511s",name)==1){total++;void*address=name[0]=='_'?dlsym(library,name+1):NULL;Dl_info owner={0};
  if(!address||!dladdr(address,&owner)||!owner.dli_fname||!realpath(owner.dli_fname,actual)||strcmp(actual,expected)){
   fprintf(stderr,"%s resolved to %s\n",name,owner.dli_fname?owner.dli_fname:"no local symbol");failed++;
  }
 }
 fclose(names);printf("%u library symbols checked, %u failures\n",total,failed);return failed?1:0;
}
