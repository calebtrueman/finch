/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../state.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/ndr.h>
static dispatch_semaphore_t received,entered,release_callback;
static unsigned packets,items,requests,sends,deallocations,activities;
static _Atomic unsigned callbacks;
static uint32_t mode;
static char queue_key;
static uint64_t self_token,new_token;
static dispatch_queue_t callback_queue;
uint32_t os_trace_get_mode(void){return mode;}
void finch_trace_state_send(xpc_object_t packet){assert(xpc_dictionary_get_uint64(packet,"operation")==2);assert(xpc_dictionary_get_uint64(packet,"aid")==987);xpc_object_t entries=xpc_dictionary_get_value(packet,"entries");size_t count=xpc_array_get_count(entries);assert(count>0&&count<=10);for(size_t i=0;i<count;i++){xpc_object_t e=xpc_array_get_value(entries,i);size_t n=0;const struct finch_state_data*d=xpc_dictionary_get_data(e,"data",&n);assert(n==203&&d->size==3&&d->type==4&&!memcmp(d->data,"abc",3));assert(!d->title[63]&&!d->object_type[63]&&!d->object_name[63]);assert(xpc_dictionary_get_uint64(e,"ttl")==14);assert(xpc_dictionary_get_uint64(e,"ts")>0);assert(xpc_dictionary_get_uuid(e,"uuid"));}packets++;items+=count;dispatch_semaphore_signal(received);}
static struct finch_state_data*make_data(const struct finch_state_hints*hints){assert(dispatch_get_specific(&queue_key)==&queue_key);assert(hints->version==1&&hints->type==3&&hints->flags==1);atomic_fetch_add(&callbacks,1);struct finch_state_data*d=malloc(203);memset(d,0xa5,203);d->type=4;d->size=3;memcpy(d->data,"abc",3);return d;}
static void wait_for(dispatch_semaphore_t s){assert(dispatch_semaphore_wait(s,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);}
/* Only this test's state.c is built with these names for its Mach calls. */
kern_return_t test_debug_control_port_for_pid(mach_port_t task,int pid,mach_port_t*out){assert(task==mach_task_self());requests++;if(pid==20)return KERN_FAILURE;*out=100+pid;return KERN_SUCCESS;}
kern_return_t test_state_mach_msg(mach_msg_header_t*head,mach_msg_option_t option,mach_msg_size_t send_size,mach_msg_size_t receive_size,mach_port_name_t receive,mach_msg_timeout_t timeout,mach_port_name_t notify){assert(option==(MACH_SEND_MSG|MACH_SEND_TIMEOUT)&&send_size==40&&!receive_size&&!receive&&timeout==50&&!notify);assert(head->msgh_bits==MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0)&&head->msgh_size==40&&head->msgh_id==50001&&!head->msgh_local_port&&!head->msgh_voucher_port);assert(head->msgh_remote_port==110||head->msgh_remote_port==130);assert(!memcmp((char*)head+24,&NDR_record,8));uint64_t aid;memcpy(&aid,(char*)head+32,8);assert(aid==1234);sends++;return KERN_SUCCESS;}
kern_return_t test_state_port_deallocate(mach_port_t task,mach_port_name_t port){assert(task==mach_task_self()&&(port==110||port==130));deallocations++;return KERN_SUCCESS;}
uint64_t test_state_activity_id(void*activity,uint64_t*unused){assert(activity==(void*)(intptr_t)-3&&!unused);return 1234;}
void test_state_activity(const void*image,const char*name,unsigned flags,void(^block)(void)){assert(image&&!strcmp(name,"System-wide statedump")&&!flags);activities++;block();}
int main(void){received=dispatch_semaphore_create(0);entered=dispatch_semaphore_create(0);release_callback=dispatch_semaphore_create(0);callback_queue=dispatch_queue_create("finch.state.wire",DISPATCH_QUEUE_SERIAL);dispatch_queue_set_specific(callback_queue,&queue_key,&queue_key,NULL);
 mode=0x100;assert(!os_state_add_handler(callback_queue,^struct finch_state_data*(const struct finch_state_hints*h){return make_data(h);}));mode=0;
 uint64_t ids[14];for(unsigned i=0;i<14;i++){unsigned index=i;ids[i]=os_state_add_handler(callback_queue,^struct finch_state_data*(const struct finch_state_hints*h){if(index==0){dispatch_semaphore_signal(entered);wait_for(release_callback);os_state_remove_handler(self_token);new_token=os_state_add_handler(callback_queue,^struct finch_state_data*(const struct finch_state_hints*next){return make_data(next);});}if(index==12)return NULL;if(index==13){struct finch_state_data*large=calloc(1,200);large->size=32569;return large;}return make_data(h);});}self_token=ids[0];
 struct finch_state_hints hints={1,0,0,3,1};finch_trace_state_request(987,&hints,14,NULL);wait_for(entered);hints.type=1;finch_trace_state_request(987,&hints,14,NULL);dispatch_semaphore_signal(release_callback);wait_for(received);wait_for(received);usleep(20000);assert(packets==2&&items==12&&atomic_load(&callbacks)==12&&new_token);
 for(unsigned i=0;i<14;i++)os_state_remove_handler(ids[i]);os_state_remove_handler(new_token);
 int pids[]={10,20,30};_os_state_request_for_pidlist(pids,3);assert(requests==3&&sends==2&&deallocations==2&&activities==1);_os_state_request_for_pidlist(NULL,0);assert(activities==2&&sends==2);dispatch_release(callback_queue);dispatch_release(received);dispatch_release(entered);dispatch_release(release_callback);puts("state wire: queued callbacks, copied hints, batching, removal, size limits and Mach messages pass");return 0;}
