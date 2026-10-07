/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../abi/cczp.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define LOAD(ret,name,args) ret(*h_##name)args=dlsym(h,#name);ret(*f_##name)args=dlsym(f,#name)
static int checks,fail;
#define CK(x) do{checks++;if(!(x)){fail++;fprintf(stderr,"line %d: %s\n",__LINE__,#x);}}while(0)
int main(int argc,char**argv){void*h=dlopen("/usr/lib/system/libcorecrypto.dylib",2),*f=dlopen(argc>1?argv[1]:"build/userland/corecrypto/rsa-test.dylib",2);if(!h||!f){puts(dlerror());return 2;}
 LOAD(size_t,cczp_n,(const struct cczp*));LOAD(size_t,cczp_bitlen,(const struct cczp*));LOAD(cc_unit*,cczp_prime,(const struct cczp*));
 LOAD(int,cczp_add,(const struct cczp*,cc_unit*,const cc_unit*,const cc_unit*));LOAD(int,cczp_sub,(const struct cczp*,cc_unit*,const cc_unit*,const cc_unit*));LOAD(int,cczp_mul,(const struct cczp*,cc_unit*,const cc_unit*,const cc_unit*));LOAD(int,cczp_mod,(const struct cczp*,cc_unit*,const cc_unit*));LOAD(int,cczp_inv,(const struct cczp*,cc_unit*,const cc_unit*));
 LOAD(int,ccrsa_init_pub,(struct cczp*,const cc_unit*,const cc_unit*));
 const struct cczp*(*cp)(void)=dlsym(h,"ccec_cp_256");const struct cczp*z=cp();
 cc_unit kh[100]={1},kf[100]={1},p[1]={65537},e[1]={17};CK(h_ccrsa_init_pub((void*)kh,p,e)==0);CK(f_ccrsa_init_pub((void*)kf,p,e)==0);
 const struct cczp*zs[]={z,(void*)kh,(void*)kf};
 for(unsigned j=0;j<3;j++){z=zs[j];size_t n=z->n;CK(h_cczp_n(z)==f_cczp_n(z));CK(h_cczp_bitlen(z)==f_cczp_bitlen(z));CK(h_cczp_prime(z)==f_cczp_prime(z));
 for(unsigned i=1;i<50;i++){cc_unit a[18]={i*57},b[18]={i*23},r[9]={0},s[9]={0};
 CK(h_cczp_add(z,r,a,b)==f_cczp_add(z,s,a,b));CK(!memcmp(r,s,n*8));CK(h_cczp_sub(z,r,a,b)==f_cczp_sub(z,s,a,b));CK(!memcmp(r,s,n*8));CK(h_cczp_mul(z,r,a,b)==f_cczp_mul(z,s,a,b));CK(!memcmp(r,s,n*8));a[n]=i;CK(h_cczp_mod(z,r,a)==f_cczp_mod(z,s,a));CK(!memcmp(r,s,n*8));a[n]=0;CK(h_cczp_inv(z,r,a)==f_cczp_inv(z,s,a));CK(!memcmp(r,s,n*8));
 }}printf("ZP ABI: %d checks, %d failures\n",checks,fail);return !!fail;}
