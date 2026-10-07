/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <CommonCrypto/CommonDH.h>
#include <CommonCrypto/CommonECCryptor.h>
#include <CommonCrypto/CommonRSACryptor.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);exit(1);}}while(0)
#define LOAD(name) __typeof__(&name) f_##name[2]={dlsym(h[0],#name),dlsym(h[1],#name)};CHECK(f_##name[0]&&f_##name[1])
int main(int argc,char**argv){if(argc!=2)return 2;void*h[2]={dlopen("/usr/lib/system/libcommonCrypto.dylib",RTLD_NOW|RTLD_LOCAL),dlopen(argv[1],RTLD_NOW|RTLD_LOCAL|RTLD_FIRST)};CHECK(h[0]&&h[1]);
 LOAD(CCDHCreate);LOAD(CCDHGenerateKey);LOAD(CCDHComputeKey);LOAD(CCDHRelease);
 CCDHRef dh[2];unsigned char pub[2][256],secret[2][256];size_t plen[2]={256,256},slen[2]={256,256};
 for(int j=0;j<2;j++){dh[j]=f_CCDHCreate[j](kCCDHRFC3526Group5);CHECK(dh[j]);CHECK(!f_CCDHGenerateKey[j](dh[j],pub[j],&plen[j]));}
 for(int j=0;j<2;j++)CHECK(!f_CCDHComputeKey[j](secret[j],&slen[j],pub[1-j],plen[1-j],dh[j]));CHECK(slen[0]==slen[1]&&!memcmp(secret[0],secret[1],slen[0]));for(int j=0;j<2;j++)f_CCDHRelease[j](dh[j]);
 LOAD(CCECCryptorGeneratePair);LOAD(CCECCryptorExportPublicKey);LOAD(CCECCryptorImportPublicKey);LOAD(CCECCryptorSignHash);LOAD(CCECCryptorVerifyHash);LOAD(CCECCryptorRelease);
 size_t bits[]={192,224,256,384,521};unsigned char digest[64]={1};
 for(unsigned b=0;b<5;b++)for(int origin=0;origin<2;origin++){
  CCECCryptorRef public,private,copy;CHECK(!f_CCECCryptorGeneratePair[origin](bits[b],&public,&private));unsigned char wire[160],sig[160];size_t wn=sizeof wire,sn=sizeof sig;CHECK(!f_CCECCryptorExportPublicKey[origin](public,wire,&wn));CHECK(!f_CCECCryptorImportPublicKey[1-origin](wire,wn,&copy));CHECK(!f_CCECCryptorSignHash[origin](private,digest,32,sig,&sn));uint32_t valid=0;CHECK(!f_CCECCryptorVerifyHash[1-origin](copy,digest,32,sig,sn,&valid)&&valid);sig[sn-1]^=1;valid=1;f_CCECCryptorVerifyHash[1-origin](copy,digest,32,sig,sn,&valid);CHECK(!valid);f_CCECCryptorRelease[origin](public);f_CCECCryptorRelease[origin](private);f_CCECCryptorRelease[1-origin](copy);
 }
 LOAD(CCRSACryptorGeneratePair);LOAD(CCRSACryptorExport);LOAD(CCRSACryptorImport);LOAD(CCRSACryptorSign);LOAD(CCRSACryptorVerify);LOAD(CCRSACryptorEncrypt);LOAD(CCRSACryptorDecrypt);LOAD(CCRSACryptorRelease);
 for(int origin=0;origin<2;origin++){
  CCRSACryptorRef public,private,copy;CHECK(!f_CCRSACryptorGeneratePair[origin](1024,65537,&public,&private));unsigned char wire[2048],sig[256],ct[256],pt[256];size_t wn=sizeof wire;CHECK(!f_CCRSACryptorExport[origin](public,wire,&wn));CHECK(!f_CCRSACryptorImport[1-origin](wire,wn,&copy));
  for(int p=0;p<2;p++){size_t sn=sizeof sig;CCAsymmetricPadding pad=p?ccRSAPSSPadding:ccPKCS1Padding;CHECK(!f_CCRSACryptorSign[origin](private,pad,digest,32,kCCDigestSHA256,16,sig,&sn));CHECK(!f_CCRSACryptorVerify[1-origin](copy,pad,digest,32,kCCDigestSHA256,16,sig,sn));sig[sn-1]^=1;CHECK(f_CCRSACryptorVerify[1-origin](copy,pad,digest,32,kCCDigestSHA256,16,sig,sn)!=0);}
  for(int p=0;p<2;p++){size_t cn=sizeof ct,pn=sizeof pt;CCAsymmetricPadding pad=p?ccOAEPPadding:ccPKCS1Padding;CHECK(!f_CCRSACryptorEncrypt[1-origin](copy,pad,digest,19,ct,&cn,NULL,0,kCCDigestSHA256));CHECK(!f_CCRSACryptorDecrypt[origin](private,pad,ct,cn,pt,&pn,NULL,0,kCCDigestSHA256));CHECK(pn==19&&!memcmp(pt,digest,19));}
  f_CCRSACryptorRelease[origin](public);f_CCRSACryptorRelease[origin](private);f_CCRSACryptorRelease[1-origin](copy);
 }
 printf("CommonCrypto keys: %u checks passed\n",checks);
}
