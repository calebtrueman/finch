/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ASCON_H
#define FINCH_ASCON_H
#include <stddef.h>
struct ccascon_info {
    size_t key_size, nonce_size, tag_size;
    int (*init)(void *,size_t,const void *,const void *,const void *);
    int (*encrypt)(void *,void *,void *,size_t,const void *,const void *);
    int (*decrypt)(void *,void *,const void *,size_t,const void *,const void *);
};
struct ccascon_cmac_info {
    size_t key_size, nonce_size, tag_size;
    int (*init)(void *,size_t,const void *,const void *,const void *);
    int (*process)(void *,size_t,const void *);
    int (*tag)(const void *,void *,const void *);
    int (*verify)(const void *,size_t,const void *,const void *);
};
#endif
