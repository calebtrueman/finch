/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#import <objc/runtime.h>
#import <os/object.h>
#import <os/object_private.h>
#include "internal.h"
@interface OS_os_log : OS_object
@end
@implementation OS_os_log
@end
/* Logs are cached for process lifetime, as on the host. */
struct finch_log *finch_log_allocate(void){return (void*)_os_object_alloc_realized((void*)[OS_os_log class],sizeof(struct finch_log));}
#import <objc/message.h>
#include <stdlib.h>
#include <string.h>
bool finch_log_object_is_public(void*value){
 if(!value)return true;Class string=objc_getClass("NSString"),number=objc_getClass("NSNumber");
 bool(*kind)(id,SEL,Class)=(void*)objc_msgSend;SEL sel=sel_registerName("isKindOfClass:");return (string&&kind((id)value,sel,string))||(number&&kind((id)value,sel,number));
}
char *finch_log_describe_object(void*value){
 if(!value)return strdup("(null)");id(*message)(id,SEL)=(void*)objc_msgSend;id description=message((id)value,sel_registerName("description"));
 const char*(*utf8)(id,SEL)=(void*)objc_msgSend;const char*s=description?utf8(description,sel_registerName("UTF8String")):NULL;return strdup(s?s:"(null)");
}
extern void os_log_with_args(struct finch_log*,uint8_t,const char*,va_list,void*);
static void cfstring_log(void*address,struct finch_log*log,unsigned trace_type,void*format,va_list args){
 const char*(*utf8)(id,SEL)=(void*)objc_msgSend;const char*s=format?utf8((id)format,sel_registerName("UTF8String")):NULL;
 if(s)os_log_with_args(log,trace_type==2?2:trace_type==4?1:0,s,args,address);
}
API void os_log_shim_with_CFString(void*address,struct finch_log*log,unsigned type,void*format,va_list args){cfstring_log(address?address:__builtin_return_address(0),log,type,format,args);}
API void os_log_shim_with_CFString_4NSLog(void*address,struct finch_log*log,unsigned type,void*format,va_list args){cfstring_log(address?address:__builtin_return_address(0),log,type,format,args);}
