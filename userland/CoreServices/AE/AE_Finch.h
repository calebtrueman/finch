/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* AE.framework's internals (userland/CoreServices/AE). */
#ifndef AE_FINCH_H
#define AE_FINCH_H

#include "../CarbonCore/CarbonCore_Finch.h"

/*
 * A descriptor's dataHandle points at the first field of its store, the
 * master pointer, as a Handle would: for plain data *dataHandle is the
 * bytes. Lists, records and Apple events hold their items (keyword and
 * owned descriptor); an Apple event also holds its attributes. A typeNull
 * descriptor has no store.
 */
enum ae_kind { AE_DATA, AE_LIST, AE_RECORD, AE_EVENT };

struct ae_item {
    AEKeyword key;
    AEDesc desc;
};

struct ae_items {
    long count, cap;
    struct ae_item *v;
};

struct ae_store {
    void *master;  /* must stay first */
    uint32_t magic;
    uint8_t kind;
    Size size;     /* AE_DATA */
    struct ae_items items;  /* AE_LIST, AE_RECORD, AE_EVENT (parameters) */
    struct ae_items attrs;  /* AE_EVENT */
};

FINCH_HIDDEN struct ae_store *ae_store(const AEDesc *d);
FINCH_HIDDEN OSErr ae_make_data(DescType type, const void *data, Size size, AEDesc *out);
FINCH_HIDDEN OSErr ae_make_container(DescType type, enum ae_kind kind, AEDesc *out);
FINCH_HIDDEN const void *ae_bytes(const AEDesc *d, Size *size);
FINCH_HIDDEN struct ae_item *ae_find(struct ae_items *items, AEKeyword key);
FINCH_HIDDEN OSErr ae_items_put(struct ae_items *items, AEKeyword key, const AEDesc *d);
FINCH_HIDDEN OSErr ae_copy_items(const struct ae_items *from, struct ae_items *to);
FINCH_HIDDEN bool ae_is_container(const AEDesc *d);

/* AECoerce.c */
FINCH_HIDDEN OSErr ae_coerce(const AEDesc *from, DescType to, AEDesc *out);

/* AEEvents.c */
FINCH_HIDDEN SInt32 ae_next_return_id(void);

/* Processes.h (ApplicationServices): the process an event is sent from. */
#ifndef kCurrentProcess
#define kCurrentProcess 2
#endif

#endif
