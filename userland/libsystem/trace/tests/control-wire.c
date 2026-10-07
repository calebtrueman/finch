/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#define debug_control_port_for_pid mock_debug_port
#define voucher_mach_msg_set mock_voucher_set
#define mach_msg mock_message
#define mach_msg_destroy mock_destroy
#define mach_port_deallocate mock_deallocate
#define mig_get_reply_port mock_reply_get
#define mig_put_reply_port mock_reply_put
#define mig_dealloc_reply_port mock_reply_dealloc
#include "../control.c"
#include <assert.h>
#include <stdio.h>
static unsigned sends,cleanups,reply_puts,reply_deallocs,destroys;
static int failure;
kern_return_t mock_debug_port(mach_port_t task,int pid,mach_port_t*out){assert(task==mach_task_self()&&pid==456);*out=failure==1?0:123;return failure==2?KERN_FAILURE:KERN_SUCCESS;}
boolean_t mock_voucher_set(mach_msg_header_t*m){assert(m->msgh_remote_port==123);return false;}
mach_port_t mock_reply_get(void){return 321;}
void mock_reply_put(mach_port_t p){assert(p==321);reply_puts++;}
void mock_reply_dealloc(mach_port_t p){assert(p==321);reply_deallocs++;}
void mock_destroy(mach_msg_header_t*m){assert(m);destroys++;}
kern_return_t mock_deallocate(ipc_space_t task,mach_port_name_t p){assert(task==mach_task_self()&&p==123);cleanups++;return 0;}
mach_msg_return_t mock_message(mach_msg_header_t*m,mach_msg_option_t options,mach_msg_size_t send,mach_msg_size_t receive,mach_port_name_t reply,mach_msg_timeout_t timeout,mach_port_name_t notify){
 sends++;assert(!notify&&m->msgh_remote_port==123);
 if(m->msgh_id==50000){assert(options==MACH_SEND_MSG&&send==44&&!receive&&!reply&&!timeout);assert(m->msgh_bits==19);uint32_t words[3];memcpy(words,(char*)m+32,12);assert(words[0]==0xaabbccdd&&!words[1]&&!words[2]);return failure==3?MACH_SEND_INVALID_DEST:0;}
 assert(m->msgh_id==50002&&m->msgh_bits==0x1513&&options==0x113&&send==24&&receive==56&&reply==321&&timeout==1000);if(failure==3)return MACH_RCV_TIMED_OUT;
 m->msgh_size=failure==4?36:48;m->msgh_id=failure==5?99:50102;m->msgh_bits=failure==6?MACH_MSGH_BITS_COMPLEX:0;m->msgh_remote_port=0;int32_t error=failure==7?KERN_FAILURE:0;memcpy((char*)m+32,&error,4);uint32_t mode=0x654321;memcpy((char*)m+36,&mode,4);return 0;
}
int main(void){for(failure=0;failure<8;failure++){unsigned before=sends;uint32_t out=0xa5a5a5a5;bool result=_os_trace_get_mode_for_pid(456,&out);assert(result==(failure==0));assert(out==(failure==0?0x654321:0xa5a5a5a5));assert(sends-before==(failure==1||failure==2?0:1));}for(failure=0;failure<4;failure++)assert(_os_trace_set_mode_for_pid(456,0xaabbccdd)==(failure==0));assert(sends==8&&cleanups==8&&reply_puts==5&&reply_deallocs==1&&destroys==4);puts("Trace control: request bytes, replies, errors and port cleanup passed (mock ports)");}
