/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_TRACE_TRANSPORT_H
#define FINCH_TRACE_TRANSPORT_H
#include "internal.h"
#include <sys/uio.h>
uint64_t finch_trace_send(uint8_t,uint64_t,uint64_t,const struct iovec*,size_t,size_t,uint32_t);
void finch_trace_register_log(struct finch_log*);
void finch_trace_log_send(struct finch_log*,uint8_t,const struct finch_log_pack*,const uint8_t*,size_t,bool);
void finch_trace_metric_send(struct finch_log*,uint8_t,const void*,const void*,uint64_t,const void*,size_t);
#endif
