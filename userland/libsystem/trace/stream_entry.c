/* Activity stream wire encoding, implemented from observed call behavior. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>

static uint64_t word(const unsigned char *e, size_t n) { uint64_t v; memcpy(&v,e+n,8); return v; }
static uint32_t small(const unsigned char *e, size_t n) { uint32_t v; memcpy(&v,e+n,4); return v; }
static void *ptr(const unsigned char *e, size_t n) { return (void *)(uintptr_t)word(e,n); }
static void put(unsigned char *e, size_t n, uint64_t v) { memcpy(e+n,&v,8); }
static void string_field(xpc_object_t d,const unsigned char *e,const char *key,size_t n) { if(ptr(e,n)) xpc_dictionary_set_string(d,key,ptr(e,n)); }
static void uuid_field(xpc_object_t d,const unsigned char *e,const char *key,size_t n) { if(ptr(e,n)) xpc_dictionary_set_uuid(d,key,ptr(e,n)); }
static void data_field(xpc_object_t d,const unsigned char *e,const char *key,size_t n) { if(ptr(e,n)&&word(e,n+8)) xpc_dictionary_set_data(d,key,ptr(e,n),word(e,n+8)); }
static size_t text_size(const unsigned char *e,size_t n,size_t limit) { return ptr(e,n)?strnlen(ptr(e,n),limit)+1:0; }
static void copy_text(unsigned char *data,size_t size,size_t at,const unsigned char *e,size_t n) { if(ptr(e,n)&&at<size) strlcpy((char *)data+at,ptr(e,n),size-at); }
static xpc_object_t encode_v1(unsigned char *e) {
    xpc_object_t d=xpc_dictionary_create(NULL,NULL,0);
    xpc_dictionary_set_uint64(d,"pid",(int64_t)(int32_t)small(e,4));
    xpc_dictionary_set_uint64(d,"procid",word(e,8));
    xpc_dictionary_set_uint64(d,"uid",small(e,16));
    xpc_dictionary_set_uint64(d,"type",small(e,0));
    uuid_field(d,e,"procuuid",20); string_field(d,e,"procpath",28);
    if(word(e,36)) xpc_dictionary_set_uint64(d,"aid",word(e,36));
    if(word(e,44)) xpc_dictionary_set_uint64(d,"paid",word(e,44));
    if(word(e,92)) {
        xpc_dictionary_set_int64(d,"timeGMTsec",(int64_t)word(e,92));
        xpc_dictionary_set_int64(d,"timeGMTusec",(int32_t)small(e,100));
    }
    if(small(e,108)) xpc_dictionary_set_int64(d,"timezoneMinutesWest",(int32_t)small(e,108));
    if(small(e,112)) xpc_dictionary_set_int64(d,"timezoneDSTflag",(int32_t)small(e,112));
    uint32_t type=small(e,0);
    if(type==0x201||type==0x203||type==0x300||type==0x400||type==0x600||type==0x800) {
        xpc_dictionary_set_uint64(d,"traceid",word(e,52));
        xpc_dictionary_set_uint64(d,"timestamp",word(e,60));
        xpc_dictionary_set_uint64(d,"thread",word(e,68));
        xpc_dictionary_set_uint64(d,"offset",word(e,116));
        xpc_dictionary_set_uint64(d,"formatoffset",word(e,124));
        uuid_field(d,e,"imageuuid",76); string_field(d,e,"imagepath",84); string_field(d,e,"name",140);
    }
    if(type==0x203) xpc_dictionary_set_bool(d,"persisted",e[148]);
    if(type==0x300) { data_field(d,e,"buffer",148); xpc_dictionary_set_value(d,"payload",ptr(e,164)); }
    if(type==0x600) { xpc_dictionary_set_uint64(d,"signpostid",word(e,204)); string_field(d,e,"signpostname",212); }
    if(type==0x400||type==0x600||type==0x800) {
        xpc_dictionary_set_uint64(d,"timeToLive",e[200]);
        string_field(d,e,"formatstring",140); data_field(d,e,"buffer",148); data_field(d,e,"privdata",164);
        string_field(d,e,"subsystem",180); string_field(d,e,"category",188);
        xpc_dictionary_set_bool(d,"persisted",e[201]);
    }
    return d;
}
static xpc_object_t encode_v2(unsigned char *e) {
    xpc_object_t d=xpc_dictionary_create(NULL,NULL,0);
    size_t imageuuid=16+text_size(e,28,4096), imagepath=imageuuid+16;
    size_t size=imagepath+text_size(e,84,4096), name=0, buffer=0, private_data=0, subsystem=0, category=0, signpost=0;
    uint32_t type=small(e,0);
    int log=type==0x400||type==0x600||type==0x800;
    if(type==0x201||type==0x203||type==0x300) {
        name=size; size+=text_size(e,140,4096);
        if(type==0x300&&ptr(e,148)&&word(e,156)) { buffer=size; size+=word(e,156); }
    } else if(log) {
        if(type==0x600) { signpost=size; size+=text_size(e,212,4096); }
        name=size; size+=text_size(e,140,65536);
        buffer=size; size+=word(e,156); private_data=size; size+=word(e,172);
        if(ptr(e,180)) { subsystem=size; size+=text_size(e,180,4096); }
        if(ptr(e,188)) { category=size; size+=text_size(e,188,4096); }
    }
    unsigned char *storage=calloc(1,236+size);
    if(!storage) { xpc_release(d); return NULL; }
    unsigned char *data=storage+236;
    if(ptr(e,20)) memcpy(data,ptr(e,20),16);
    copy_text(data,size,16,e,28);
    if(ptr(e,76)) memcpy(data+imageuuid,ptr(e,76),16);
    copy_text(data,size,imagepath,e,84);
    put(e,20,0); put(e,28,16); put(e,76,imageuuid); put(e,84,imagepath);
    if(type==0x201||type==0x203||type==0x300||log) {
        if(ptr(e,140)) { copy_text(data,size,name,e,140); put(e,140,name); }
    }
    if(type==0x300) {
        if(ptr(e,148)&&word(e,156)) { memcpy(data+buffer,ptr(e,148),word(e,156)); put(e,148,buffer); }
        xpc_dictionary_set_value(d,"payload",ptr(e,164));
    }
    if(log) {
        if(type==0x600&&ptr(e,212)) { copy_text(data,size,signpost,e,212); put(e,212,signpost); }
        if(word(e,156)) memcpy(data+buffer,ptr(e,148),word(e,156));
        if(word(e,172)) memcpy(data+private_data,ptr(e,164),word(e,172));
        copy_text(data,size,subsystem,e,180); copy_text(data,size,category,e,188);
        put(e,148,buffer); put(e,164,private_data); put(e,180,subsystem); put(e,188,category);
    }
    memcpy(storage,e,236);
    xpc_dictionary_set_data(d,"entryData",storage,236+size);
    free(storage); return d;
}
xpc_object_t _os_activity_stream_entry_encode(void *entry,uint64_t version) {
    if(version!=1&&version!=2) __builtin_trap();
    unsigned char *e=entry;
    xpc_object_t d=version==1?encode_v1(e):encode_v2(e);
    if(d) {
        if(e[132]&1) xpc_dictionary_set_bool(d,"32bits",true);
        xpc_dictionary_set_uint64(d,"action",6); xpc_dictionary_set_uint64(d,"version",version);
    }
    return d;
}
