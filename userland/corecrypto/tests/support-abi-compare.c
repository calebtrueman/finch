/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/ccdigest.h"
#include "../abi/chacha.h"
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#define CHECK(x) do{if(!(x)){fprintf(stderr,"line %d failed: %s\n",__LINE__,#x);exit(1);}}while(0)
struct result{size_t count,failures;const void*first;};
struct list{unsigned type;const void*const*items;size_t count;};
struct digest{unsigned type;const struct ccdigest_info*(*di)(void);const void*message;size_t n;const void*expected;};
struct curve{unsigned type;const void*pub,*priv,*expected;unsigned expectation;};
struct chacha{unsigned type;const void*key;size_t key_n;const void*nonce;size_t nonce_n;const void*aad;size_t aad_n;const void*plain;size_t plain_n;const void*cipher;size_t cipher_n;const void*tag;size_t tag_n;unsigned bad;};
int main(int argc,char**argv){CHECK(argc==2);void*lib[2]={dlopen("/usr/lib/system/libcorecrypto.dylib",RTLD_NOW|RTLD_LOCAL),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL)};CHECK(lib[0]&&lib[1]);int(*post[2])(const void*,struct result*);const char*(*name[2])(unsigned);for(int j=0;j<2;j++){post[j]=dlsym(lib[j],"ccpost");name[j]=dlsym(lib[j],"cc_impl_name");Dl_info info;CHECK(dladdr((void*)post[j],&info));if(j)CHECK(strstr(info.dli_fname,argv[1]));}
 for(unsigned i=0;i<200;i++)CHECK(!strcmp(name[0](i),name[1](i)));CHECK(!strcmp(name[0](~0u),name[1](~0u)));
 const struct ccdigest_info*(*sha)(void)=dlsym(lib[0],"ccsha256_di");void(*hash)(const struct ccdigest_info*,size_t,const void*,void*)=dlsym(lib[0],"ccdigest");unsigned char expected[32],bad[32]={0};hash(sha(),3,"abc",expected);struct digest dg={1,sha,"abc",3,expected},db={1,sha,"abc",3,bad};unsigned unknown=50;const void*items[]={&dg,&db,&unknown,NULL};struct list ls={0,items,4};
 unsigned char priv[32]={1},pub[32]={9},shared[32],zero[32]={0};int(*dh)(void*,const void*,const void*)=dlsym(lib[0],"cccurve25519");CHECK(!dh(shared,priv,pub));struct curve cv={2,pub,priv,shared,0},cb={2,zero,priv,shared,2};
 unsigned char key[32]={0},nonce[12]={0},ct[9],tag[16];const struct ccchacha20poly1305_info*(*ci)(void)=dlsym(lib[0],"ccchacha20poly1305_info");int(*encrypt)(const struct ccchacha20poly1305_info*,const void*,const void*,size_t,const void*,size_t,const void*,void*,void*)=dlsym(lib[0],"ccchacha20poly1305_encrypt_oneshot");CHECK(!encrypt(ci(),key,nonce,3,"aad",9,"plaintext",ct,tag));struct chacha ca={3,key,32,nonce,12,"aad",3,"plaintext",9,ct,9,tag,16,0};
 const void*vectors[]={NULL,&dg,&db,&unknown,&ls,&cv,&cb,&ca};for(size_t i=0;i<sizeof(vectors)/sizeof(*vectors);i++){struct result r[2];int x=post[0](vectors[i],&r[0]),y=post[1](vectors[i],&r[1]);CHECK(x==y);CHECK(!memcmp(r,r+1,sizeof(r[0])));CHECK(post[1](vectors[i],NULL)==y);}
 for(int expectation=0;expectation<3;expectation++){ca.bad=expectation;tag[0]^=1;struct result r[2];CHECK(post[0](&ca,&r[0])==post[1](&ca,&r[1]));CHECK(!memcmp(r,r+1,sizeof(r[0])));tag[0]^=1;}
 for(int j=0;j<2;j++){void(*cond)(int,const char*)=dlsym(lib[j],"cc_try_abort_if");cond(0,"no abort");const char*names[]={"cc_abort","cc_try_abort"};for(size_t a=0;a<2;a++){void(*stop)(const char*)=dlsym(lib[j],names[a]);pid_t child=fork();CHECK(child>=0);if(!child){struct rlimit limit={0,0};setrlimit(RLIMIT_CORE,&limit);stop("test");_exit(91);}int status;CHECK(waitpid(child,&status,0)==child);CHECK(WIFSIGNALED(status)&&WTERMSIG(status)==SIGABRT);}}
 puts("Support: names, abort behavior and all POST vector types match host results");return 0;}
