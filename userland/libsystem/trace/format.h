/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_TRACE_FORMAT_H
#define FINCH_TRACE_FORMAT_H
#include <stddef.h>
#include <stdint.h>
/* Compiler-built argument records hold native values and pointers. */
char *finch_log_compose(const char *,const uint8_t *,size_t,int,char *,size_t);
struct finch_log_wire { uint8_t *public_data;size_t public_size; };
int finch_log_flatten(const uint8_t*,size_t,int,struct finch_log_wire*);
char *finch_log_compose_wire(const char*,const uint8_t*,size_t,const uint8_t*,size_t);
#include <stdarg.h>
uint8_t *finch_log_pack_arguments(const char*,va_list,size_t*);

char *finch_log_compose_saved(const char*,const uint8_t*,size_t);
#endif
