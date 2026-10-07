/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_TRACE_IMAGE_H
#define FINCH_TRACE_IMAGE_H
#include <stddef.h>
#include <stdint.h>
struct finch_trace_image_range { uint32_t offset,size,address; };
struct finch_trace_image_info {
 uint8_t encrypted,mutable_image,reserved[6];
 const unsigned char *uuid;
 struct finch_trace_image_range ranges[5];
 uint32_t padding;
};
size_t _os_trace_get_image_info(const void*,size_t,unsigned char*,struct finch_trace_image_info*,unsigned);
int _os_trace_macho_for_each_slice(const void*,size_t,int(^)(const void*,size_t));
#endif
