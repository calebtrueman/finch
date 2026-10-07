/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_LEGACY_CIPHERS_H
#define FINCH_LEGACY_CIPHERS_H
#include "ccmode.h"
struct ccrc4_info { size_t size; void (*init)(void *,size_t,const void *); void (*crypt)(void *,size_t,const void *,void *); };
#endif
