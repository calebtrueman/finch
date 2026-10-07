/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../metric.h"
#include <os/object.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <math.h>
struct api{
 struct metric_label*(*label)(const void*,size_t,const struct metric_label_part*);
 struct metric_label*(*label_args)(const void*,size_t,uint64_t,const char*,...);
 struct metric_dimensions*(*dimensions)(unsigned);bool(*add)(struct metric_dimensions*,const char*,const char*);
 struct metric_group*(*group)(const char*,const char*,struct metric_dimensions*);
 struct metric*(*create[3])(struct metric_group*,const char*,struct metric_dimensions*,unsigned,unsigned,unsigned,unsigned,unsigned);
 void(*integers[2])(struct metric*,unsigned,uint64_t,const void*);void(*number)(struct metric*,unsigned,double,const void*);
 void(*reset)(struct metric*,const void*);void(*scale)(struct metric*,unsigned);void(*unit)(struct metric*,unsigned);
};
static struct api load(void*h){struct api a={0};a.label=dlsym(h,"_os_metric_label_create_v");a.label_args=dlsym(h,"_os_metric_label_create_impl");a.dimensions=dlsym(h,"os_metric_dimensions_create");a.add=dlsym(h,"os_metric_dimensions_add");a.group=dlsym(h,"os_metric_group_create");a.create[0]=dlsym(h,"_os_metric_int64_create_impl");a.create[1]=dlsym(h,"_os_metric_double_create_impl");a.create[2]=dlsym(h,"_os_metric_uint64_create_impl");a.integers[0]=dlsym(h,"_os_metric_int64_op_impl");a.integers[1]=dlsym(h,"_os_metric_uint64_op_impl");a.number=dlsym(h,"_os_metric_double_op_impl");a.reset=dlsym(h,"_os_metric_reset_impl");a.unit=dlsym(h,"_os_metric_set_unit_impl");a.scale=dlsym(h,"_os_metric_set_scale_impl");return a;}
static void label_equal(struct metric_label*a,struct metric_label*b){assert(!!a==!!b);if(!a)return;assert(a->size==b->size&&a->strings_size==b->strings_size);assert(!memcmp(a->data,b->data,a->size));if(a->strings_size)assert(!memcmp(a->strings,b->strings,a->strings_size));}
int main(int argc,char**argv){assert(argc==2);void*h=dlopen("/usr/lib/system/libsystem_trace.dylib",RTLD_NOW|RTLD_LOCAL),*f=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);assert(h&&f);struct api a[]={load(h),load(f)};Dl_info info;assert(dladdr((void*)a[1].create[0],&info)&&strstr(info.dli_fname,argv[1]));unsigned checks=0;
 const char*words[]={"metric","test","longer label","", "a/b:c"};
 for(unsigned count=1;count<16;count++)for(unsigned types=0;types<3;types++){struct metric_label_part parts[16];for(unsigned i=0;i<count;i++)parts[i]=(struct metric_label_part){types==0?0:types==1?1:i%2,words[i%5]};struct metric_label*l[]={a[0].label(main,count,parts),a[1].label(main,count,parts)};label_equal(l[0],l[1]);for(unsigned j=0;j<2;j++)os_release(l[j]);checks++;}
 for(unsigned n=2000;n<4100;n+=11){char*word=malloc(n+1);memset(word,'x',n);word[n]=0;struct metric_label*l[]={a[0].label_args(main,2,UINT64_C(0),"key",UINT64_C(0),word),a[1].label_args(main,2,UINT64_C(0),"key",UINT64_C(0),word)};label_equal(l[0],l[1]);for(unsigned j=0;j<2;j++)if(l[j])os_release(l[j]);free(word);checks++;}
 for(unsigned capacity=0;capacity<8;capacity++){struct metric_dimensions*d[]={a[0].dimensions(capacity),a[1].dimensions(capacity)};for(unsigned n=0;n<capacity+2;n++){assert(a[0].add(d[0],"name",words[n%5])==a[1].add(d[1],"name",words[n%5]));assert(d[0]->count==d[1]->count);for(unsigned k=0;k<d[0]->count;k++)label_equal(d[0]->labels[k],d[1]->labels[k]);}for(unsigned j=0;j<2;j++)os_release(d[j]);checks++;}
 struct metric_group*g[]={a[0].group("finch.metric.test","compare",NULL),a[1].group("finch.metric.test","compare",NULL)};g[0]->log=g[1]->log=dlsym(h,"_os_log_disabled");
 const uint64_t values[]={0,1,4,UINT64_MAX,INT64_MAX,UINT64_C(0x8000000000000000),17,UINT64_C(0x1020304050607080)};const double decimals[]={0,1.5,-2.25,100.9,1e20,-1e20,17.125,NAN,INFINITY,-INFINITY};
 for(unsigned type=0;type<3;type++)for(unsigned stats=0;stats<3;stats++)for(unsigned bins=0;bins<18;bins+=bins?7:1)for(unsigned width=0;width<9;width+=4)for(unsigned kind=0;kind<2;kind++){
 struct metric*m[]={a[0].create[type](g[0],"value",NULL,kind,stats,bins,width,3),a[1].create[type](g[1],"value",NULL,kind,stats,bins,width,3)};size_t bytes=16+8+40*stats+8*bins;assert(!memcmp(&m[0]->kind,&m[1]->kind,bytes));label_equal(m[0]->label,m[1]->label);
 for(unsigned turn=0;turn<40;turn++){for(unsigned j=0;j<2;j++){unsigned from=turn%3==2?1-j:j;if(turn==16)a[from].reset(m[j],main);else if(type==1)a[from].number(m[j],turn%4,decimals[turn%(sizeof(decimals)/sizeof(*decimals))],main);else a[from].integers[type==2](m[j],turn%4,values[turn%8],main);a[from].unit(m[j],turn);a[from].scale(m[j],turn*19);}
 if(memcmp(&m[0]->kind,&m[1]->kind,bytes)){fprintf(stderr,"metric type%u stats%u bins%u width%u kind%u turn%u\n",type,stats,bins,width,kind,turn);for(size_t k=0;k<bytes;k++)if((&m[0]->kind)[k]!=(&m[1]->kind)[k])fprintf(stderr,"offset%zu %02x/%02x\n",40+k,(&m[0]->kind)[k],(&m[1]->kind)[k]);return 1;}checks++;}
 for(unsigned j=0;j<2;j++)os_release(m[j]);}
 for(unsigned j=0;j<2;j++)os_release(g[j]);printf("metrics: %u host comparisons passed, including mixed calls and cleanup\n",checks);return 0;
}
