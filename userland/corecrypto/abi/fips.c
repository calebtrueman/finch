/* SPDX-License-Identifier: MIT OR Apache-2.0
 * Independent startup checks. These checks do not confer FIPS certification.
 * Finch seals its own text sections after linking and before code signing.
 * The seal catches accidental image changes; it is not a certification.
 */
#include "ccdigest.h"
#include "cchmac.h"
#include "ccmode.h"
#include "ccec.h"
#include <openssl/crypto.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <string.h>
#define EXPORT __attribute__((visibility("default")))

EXPORT const unsigned char CCMLDSA_FAULT_CANARY[16]={
    0x43,0x4c,0xeb,0xbf,0xdf,0x72,0xed,0xc3,
    0x87,0xfd,0xc7,0x81,0xa0,0x22,0xd5,0xd9
};
/* The measured host export is one pointer, not an inline callback table. */
EXPORT void *fipspost_trace_vtable;

static const volatile unsigned char finch_integrity_seal[32]
    __attribute__((used,section("__TEXT,__finch_seal")))={0};
EXPORT int fipspost_post(uint32_t,const void*);

static int section_name(const char name[16],const char*expected){
    return !strncmp(name,expected,16);
}
/* The linker defines __dso_handle as this image's own Mach-O header, so the
 * check finds itself without dladdr (and without a libdyld dependency that
 * Apple's library doesn't have). */
extern const struct mach_header_64 __dso_handle;
static int check_integrity(const void*image){
    const struct mach_header_64*header=&__dso_handle;
    if(image&&image!=(const void*)header)return -2072;
    if(header->magic!=MH_MAGIC_64||header->cputype!=CPU_TYPE_ARM64||
       (header->cpusubtype&~CPU_SUBTYPE_MASK)!=CPU_SUBTYPE_ARM64E)return -2072;
    const unsigned char*commands=(const unsigned char*)(header+1);
    if(header->sizeofcmds>32*1024*1024||header->ncmds>header->sizeofcmds/sizeof(struct load_command))return -2072;
    const unsigned char*end=commands+header->sizeofcmds,*cursor=commands;
    const struct segment_command_64*text=NULL;
    for(uint32_t i=0;i<header->ncmds;i++){
        if((size_t)(end-cursor)<sizeof(struct load_command))return -2072;
        const struct load_command*lc=(const void*)cursor;
        if(lc->cmdsize<sizeof(*lc)||lc->cmdsize>(size_t)(end-cursor))return -2072;
        if(lc->cmd==LC_SEGMENT_64){
            if(lc->cmdsize<sizeof(struct segment_command_64))return -2072;
            const struct segment_command_64*segment=(const void*)lc;
            if(section_name(segment->segname,"__TEXT")){
                if(text||segment->nsects>(lc->cmdsize-sizeof(*segment))/sizeof(struct section_64))return -2072;
                text=segment;
            }
        }
        cursor+=lc->cmdsize;
    }
    if(cursor!=end||!text||text->fileoff||text->filesize>text->vmsize||
       text->filesize<sizeof(*header)+header->sizeofcmds)return -2072;
    const struct ccdigest_info*di=ccsha256_di();
    _Alignas(16) unsigned char state[256],actual[32];
    if(ccdigest_di_size(di)>sizeof state)return -2072;
    ccdigest_init(di,state);
    const struct section_64*section=(const void*)(text+1);
    unsigned found_seal=0,content_sections=0;int rc=-2072;
    for(uint32_t i=0;i<text->nsects;i++,section++){
        if(!section_name(section->segname,"__TEXT")||section->addr<text->vmaddr)goto done;
        unsigned kind=section->flags&SECTION_TYPE;
        if(kind==S_ZEROFILL||kind==S_GB_ZEROFILL||kind==S_THREAD_LOCAL_ZEROFILL)goto done;
        uint64_t offset=section->addr-text->vmaddr;
        if(offset>text->filesize||section->size>text->filesize-offset||section->offset!=offset)goto done;
        const unsigned char*bytes=(const unsigned char*)header+(size_t)offset;
        if(section_name(section->sectname,"__finch_seal")){
            if(found_seal++||section->size!=sizeof finch_integrity_seal||
               bytes!=(const unsigned char*)finch_integrity_seal)goto done;
        }else{
            ccdigest_update(di,state,(size_t)section->size,bytes);
            content_sections++;
        }
    }
    if(found_seal!=1||!content_sections)goto done;
    di->final(di,state,actual);
    unsigned nonzero=0,difference=0;
    for(size_t i=0;i<sizeof actual;i++){
        unsigned expected=finch_integrity_seal[i];
        nonzero|=expected;difference|=expected^actual[i];
    }
    rc=nonzero&&!difference?0:-2074;
done:
    OPENSSL_cleanse(state,sizeof state);OPENSSL_cleanse(actual,sizeof actual);return rc;
}

extern int cchkdf(const struct ccdigest_info*,size_t,const void*,size_t,const void*,size_t,const void*,size_t,void*);
extern int ccpbkdf2_hmac(const struct ccdigest_info*,size_t,const void*,size_t,const void*,uint64_t,size_t,void*);
extern int ccec_sign_composite(const struct ccec_ctx*,size_t,const void*,void*,void*,struct ccrng_state*);
extern int ccec_verify_composite_digest(const struct ccec_ctx*,size_t,const void*,const void*,const void*,void*);
extern int ccecdh_compute_shared_secret(const struct ccec_ctx*,const struct ccec_ctx*,size_t*,void*,struct ccrng_state*);

static unsigned hex_digit(char c){return c<='9'?(unsigned)(c-'0'):(unsigned)(c-'a'+10);}
static void read_hex(unsigned char*out,const char*hex){for(size_t i=0;hex[2*i];i++)out[i]=(unsigned char)((hex_digit(hex[2*i])<<4)|hex_digit(hex[2*i+1]));}
static int matches(const unsigned char*out,size_t n,const char*expected){
    unsigned difference=0;
    for(size_t i=0;i<n;i++)difference|=out[i]^((hex_digit(expected[2*i])<<4)|hex_digit(expected[2*i+1]));
    return difference==0;
}
static int check_hmac(uint32_t mode){
    unsigned char key[20],out[32];memset(key,0x0b,sizeof key);
    cchmac(ccsha256_di(),sizeof key,key,8,"Hi There",out);
    /* Like the host, force-failure mode damages a computed answer. */
    if(mode&16)out[0]^=1;
    int ok=matches(out,sizeof out,"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    OPENSSL_cleanse(out,sizeof out);return ok?0:-1075;
}
static int check_digest(void){
    unsigned char out[64];ccdigest(ccsha256_di(),3,"abc",out);
    int ok=matches(out,32,"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    ccdigest(ccsha512_di(),3,"abc",out);
    ok&=matches(out,64,"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
    OPENSSL_cleanse(out,sizeof out);return ok?0:-3075;
}
static int check_aes(void){
    unsigned char key[16],plain[16],cipher[16],expected[16],decoded[16];
    read_hex(key,"000102030405060708090a0b0c0d0e0f");
    read_hex(plain,"00112233445566778899aabbccddeeff");
    read_hex(expected,"69c4e0d86a7b0430d8cdb78070b4c55a");
    int ok=!ccecb_one_shot(ccaes_ecb_encrypt_mode(),16,key,1,plain,cipher)&&!memcmp(cipher,expected,16);
    ok&=!ccecb_one_shot(ccaes_ecb_decrypt_mode(),16,key,1,expected,decoded)&&!memcmp(decoded,plain,16);
    OPENSSL_cleanse(key,sizeof key);OPENSSL_cleanse(decoded,sizeof decoded);
    return ok?0:-4075;
}
static int check_kdf(void){
    unsigned char ikm[22],salt[13],info[10],out[42];memset(ikm,0x0b,sizeof ikm);
    for(unsigned i=0;i<sizeof salt;i++)salt[i]=(unsigned char)i;
    for(unsigned i=0;i<sizeof info;i++)info[i]=(unsigned char)(0xf0+i);
    int ok=!cchkdf(ccsha256_di(),sizeof ikm,ikm,sizeof salt,salt,sizeof info,info,sizeof out,out);
    ok&=matches(out,sizeof out,"3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865");
    OPENSSL_cleanse(out,sizeof out);return ok?0:-11075;
}
static int check_password_kdf(void){
    unsigned char out[32];int ok=!ccpbkdf2_hmac(ccsha256_di(),8,"password",4,"salt",1,sizeof out,out);
    ok&=matches(out,sizeof out,"120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");
    OPENSSL_cleanse(out,sizeof out);return ok?0:-12075;
}
static int zero_random(struct ccrng_state*r,size_t n,void*out){(void)r;memset(out,0,n);return 0;}
static int check_ec(void){
    /* Zero input to the FIPS scalar sampler selects scalar one. The public
     * point, shared secret, and ECDSA signature then have fixed answers. */
    _Alignas(16) unsigned char storage[144]={0};struct ccec_ctx*k=(void*)storage;
    struct ccrng_state rng={zero_random};unsigned char pub[65],x[32],r[32],s[32],digest[32]={0};
    const char*gx="6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296";
    const char*gy="4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5";
    int rc=-7075;
    if(ccec_generate_key(ccec_cp_256(),&rng,k)||ccec_export_pub(k,pub)||pub[0]!=4||!matches(pub+1,32,gx)||!matches(pub+33,32,gy))goto done;
    size_t n=sizeof x;
    if(ccecdh_compute_shared_secret(k,k,&n,x,&rng)||n!=32||!matches(x,32,gx))goto done;
    if(ccec_sign_composite(k,32,digest,r,s,&rng)||!matches(r,32,gx)||!matches(s,32,gx))goto done;
    if(ccec_verify_composite_digest(k,32,digest,r,s,NULL))goto done;
    digest[0]=1;
    if(ccec_verify_composite_digest(k,32,digest,r,s,NULL)==0)goto done;
    rc=0;
done:
    OPENSSL_cleanse(storage,sizeof storage);OPENSSL_cleanse(x,sizeof x);
    OPENSSL_cleanse(r,sizeof r);OPENSSL_cleanse(s,sizeof s);return rc;
}
EXPORT int fipspost_post(uint32_t mode,const void*image){
    /* These mode bits match observed host behavior. Mode 256 suppresses the
     * return code after running checks; it does not bypass their execution. */
    if(mode&4)return 0;
    int first=check_hmac(mode),rc;
    if(!(mode&64)&&(rc=check_integrity(image))&&!first)first=rc;
    if((rc=check_digest())&&!first)first=rc;
    if((rc=check_aes())&&!first)first=rc;
    if((rc=check_ec())&&!first)first=rc;
    if((rc=check_kdf())&&!first)first=rc;
    if((rc=check_password_kdf())&&!first)first=rc;
    return mode&256?0:first;
}
