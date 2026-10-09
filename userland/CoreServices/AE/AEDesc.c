/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Apple event descriptors: plain data, lists, records and Apple events
 * (AEDataModel.h), with Apple's results for the edge cases: a typeNull
 * descriptor has no storage, putting an item at 0 or count+1 appends and
 * at 1..count replaces, records refuse indexed puts (errAEWrongDataType),
 * parameter calls on anything not a record are errAENotAEDesc, attribute
 * calls on a record that isn't an Apple event are paramErr, and a missing
 * item is errAEDescNotFound. Duplicates are deep copies.
 */
#include "AE_Finch.h"

#define AE_MAGIC 0x46416544u /* 'FAeD' */

struct ae_store *
ae_store(const AEDesc *d)
{
    if (!d || !d->dataHandle)
        return NULL;
    struct ae_store *s = (struct ae_store *)d->dataHandle;
    return s->magic == AE_MAGIC ? s : NULL;
}

bool
ae_is_container(const AEDesc *d)
{
    struct ae_store *s = ae_store(d);
    return s && s->kind != AE_DATA;
}

static struct ae_store *
new_store(enum ae_kind kind, Size size)
{
    struct ae_store *s = calloc(1, sizeof *s + (kind == AE_DATA ? (size_t)size + 1 : 0));
    if (!s)
        return NULL;
    s->magic = AE_MAGIC;
    s->kind = kind;
    s->size = size;
    s->master = kind == AE_DATA ? (void *)(s + 1) : (void *)s;
    return s;
}

OSErr
ae_make_data(DescType type, const void *data, Size size, AEDesc *out)
{
    out->descriptorType = typeNull;
    out->dataHandle = NULL;
    if (size < 0)
        return paramErr;
    if (type == typeNull)
        return noErr;
    struct ae_store *s = new_store(AE_DATA, size);
    if (!s)
        return memFullErr;
    if (size && data)
        memcpy(s + 1, data, size);
    out->descriptorType = type;
    out->dataHandle = (AEDataStorage)&s->master;
    return noErr;
}

OSErr
ae_make_container(DescType type, enum ae_kind kind, AEDesc *out)
{
    struct ae_store *s = new_store(kind, 0);
    if (!s)
        return memFullErr;
    out->descriptorType = type;
    out->dataHandle = (AEDataStorage)&s->master;
    return noErr;
}

const void *
ae_bytes(const AEDesc *d, Size *size)
{
    struct ae_store *s = ae_store(d);
    if (!s || s->kind != AE_DATA) {
        *size = 0;
        return "";
    }
    *size = s->size;
    return s + 1;
}

static void
free_items(struct ae_items *items)
{
    for (long i = 0; i < items->count; i++)
        AEDisposeDesc(&items->v[i].desc);
    free(items->v);
    items->v = NULL;
    items->count = items->cap = 0;
}

struct ae_item *
ae_find(struct ae_items *items, AEKeyword key)
{
    for (long i = 0; i < items->count; i++)
        if (items->v[i].key == key)
            return &items->v[i];
    return NULL;
}

static OSErr
items_insert(struct ae_items *items, long at, AEKeyword key, const AEDesc *d)
{
    if (items->count == items->cap) {
        long cap = items->cap ? items->cap * 2 : 4;
        struct ae_item *v = realloc(items->v, cap * sizeof *v);
        if (!v)
            return memFullErr;
        items->v = v;
        items->cap = cap;
    }
    AEDesc copy;
    OSErr e = AEDuplicateDesc(d, &copy);
    if (e)
        return e;
    memmove(&items->v[at + 1], &items->v[at], (items->count - at) * sizeof *items->v);
    items->v[at].key = key;
    items->v[at].desc = copy;
    items->count++;
    return noErr;
}

/* Replaces the keyword's item in place, or appends it. */
OSErr
ae_items_put(struct ae_items *items, AEKeyword key, const AEDesc *d)
{
    struct ae_item *it = ae_find(items, key);
    if (it) {
        AEDesc copy;
        OSErr e = AEDuplicateDesc(d, &copy);
        if (e)
            return e;
        AEDisposeDesc(&it->desc);
        it->desc = copy;
        return noErr;
    }
    return items_insert(items, items->count, key, d);
}

OSErr
ae_copy_items(const struct ae_items *from, struct ae_items *to)
{
    for (long i = 0; i < from->count; i++) {
        OSErr e = items_insert(to, to->count, from->v[i].key, &from->v[i].desc);
        if (e)
            return e;
    }
    return noErr;
}

#pragma mark - Plain descriptors

void
AEInitializeDesc(AEDesc *desc)
{
    desc->descriptorType = typeNull;
    desc->dataHandle = NULL;
}

OSErr
AECreateDesc(DescType typeCode, const void *dataPtr, Size dataSize, AEDesc *result)
{
    if (!result)
        return paramErr;
    return ae_make_data(typeCode, dataPtr, dataSize, result);
}

OSErr
AEDisposeDesc(AEDesc *theAEDesc)
{
    if (!theAEDesc)
        return noErr;
    struct ae_store *s = ae_store(theAEDesc);
    if (s) {
        free_items(&s->items);
        free_items(&s->attrs);
        s->magic = 0;
        free(s);
    }
    theAEDesc->descriptorType = typeNull;
    theAEDesc->dataHandle = NULL;
    return noErr;
}

OSErr
AEDuplicateDesc(const AEDesc *theAEDesc, AEDesc *result)
{
    if (!theAEDesc || !result)
        return paramErr;
    AEDesc src = *theAEDesc;  /* result may be theAEDesc */
    struct ae_store *s = ae_store(&src);
    if (!s) {
        result->descriptorType = src.dataHandle ? typeNull : src.descriptorType;
        result->dataHandle = NULL;
        return noErr;
    }
    if (s->kind == AE_DATA)
        return ae_make_data(src.descriptorType, s + 1, s->size, result);
    AEDesc out;
    OSErr e = ae_make_container(src.descriptorType, s->kind, &out);
    if (e)
        return e;
    struct ae_store *d = ae_store(&out);
    if ((e = ae_copy_items(&s->items, &d->items)) || (e = ae_copy_items(&s->attrs, &d->attrs))) {
        AEDisposeDesc(&out);
        return e;
    }
    *result = out;
    return noErr;
}

Size
AEGetDescDataSize(const AEDesc *theAEDesc)
{
    Size n;
    ae_bytes(theAEDesc, &n);
    return n;
}

OSErr
AEGetDescData(const AEDesc *theAEDesc, void *dataPtr, Size maximumSize)
{
    if (!theAEDesc)
        return paramErr;
    Size n;
    const void *p = ae_bytes(theAEDesc, &n);
    if (dataPtr && maximumSize > 0)
        memcpy(dataPtr, p, n < maximumSize ? n : maximumSize);
    return noErr;
}

OSStatus
AEGetDescDataRange(const AEDesc *dataDesc, void *buffer, Size offset, Size length)
{
    if (!dataDesc || offset < 0 || length < 0)
        return paramErr;
    Size n;
    const unsigned char *p = ae_bytes(dataDesc, &n);
    if (offset < n && buffer)
        memcpy(buffer, p + offset, (offset + length <= n) ? length : n - offset);
    return noErr;
}

OSErr
AEReplaceDescData(DescType typeCode, const void *dataPtr, Size dataSize, AEDesc *theAEDesc)
{
    AEDesc d;
    OSErr e = ae_make_data(typeCode, dataPtr, dataSize, &d);
    if (e)
        return e;
    AEDisposeDesc(theAEDesc);
    *theAEDesc = d;
    return noErr;
}

OSStatus
AECreateDescFromExternalPtr(OSType descriptorType, const void *dataPtr, Size dataLength,
                            AEDisposeExternalUPP disposeCallback, SRefCon disposeRefcon, AEDesc *theDesc)
{
    OSErr e = ae_make_data(descriptorType, dataPtr, dataLength, theDesc);
    if (!e && disposeCallback)
        disposeCallback(dataPtr, dataLength, disposeRefcon);  /* copied: the caller's buffer is free now */
    return e;
}

#pragma mark - Lists and records

OSErr
AECreateList(const void *factoringPtr, Size factoredSize, Boolean isRecord, AEDescList *resultList)
{
    if (!resultList)
        return paramErr;
    return ae_make_container(isRecord ? typeAERecord : typeAEList, isRecord ? AE_RECORD : AE_LIST, resultList);
}

Boolean
AECheckIsRecord(const AEDesc *theDesc)
{
    struct ae_store *s = ae_store(theDesc);
    return s && (s->kind == AE_RECORD || s->kind == AE_EVENT);
}

OSErr
AECountItems(const AEDescList *theAEDescList, long *theCount)
{
    struct ae_store *s = ae_store(theAEDescList);
    if (!s || s->kind == AE_DATA)
        return errAEWrongDataType;
    if (theCount)
        *theCount = s->items.count;
    return noErr;
}

OSErr
AEPutDesc(AEDescList *theAEDescList, long index, const AEDesc *theAEDesc)
{
    struct ae_store *s = ae_store(theAEDescList);
    if (!s || s->kind != AE_LIST)
        return errAEWrongDataType;
    if (index == 0 || index == s->items.count + 1)
        return items_insert(&s->items, s->items.count, typeWildCard, theAEDesc);
    if (index < 0 || index > s->items.count)
        return errAEIllegalIndex;
    AEDesc copy;
    OSErr e = AEDuplicateDesc(theAEDesc, &copy);
    if (e)
        return e;
    AEDisposeDesc(&s->items.v[index - 1].desc);
    s->items.v[index - 1].desc = copy;
    return noErr;
}

OSErr
AEPutPtr(AEDescList *theAEDescList, long index, DescType typeCode, const void *dataPtr, Size dataSize)
{
    AEDesc d;
    OSErr e = ae_make_data(typeCode, dataPtr, dataSize, &d);
    if (e)
        return e;
    e = AEPutDesc(theAEDescList, index, &d);
    AEDisposeDesc(&d);
    return e;
}

static OSErr
nth(const AEDescList *list, long index, struct ae_item **out)
{
    struct ae_store *s = ae_store(list);
    if (!s || s->kind == AE_DATA)
        return errAEWrongDataType;
    if (index < 1 || index > s->items.count)
        return errAEDescNotFound;
    *out = &s->items.v[index - 1];
    return noErr;
}

/* An item as the caller wants it, into a buffer: Apple's *Ptr calls. */
static OSErr
to_ptr(const AEDesc *d, DescType desiredType, DescType *typeCode, void *dataPtr, Size maximumSize, Size *actualSize)
{
    AEDesc c;
    OSErr e = ae_coerce(d, desiredType, &c);
    if (e)
        return e;
    Size n;
    const void *p = ae_bytes(&c, &n);
    if (typeCode)
        *typeCode = c.descriptorType;
    if (actualSize)
        *actualSize = n;
    if (dataPtr && maximumSize > 0)
        memcpy(dataPtr, p, n < maximumSize ? n : maximumSize);
    AEDisposeDesc(&c);
    return noErr;
}

OSErr
AEGetNthPtr(const AEDescList *theAEDescList, long index, DescType desiredType, AEKeyword *theAEKeyword,
            DescType *typeCode, void *dataPtr, Size maximumSize, Size *actualSize)
{
    struct ae_item *it;
    OSErr e = nth(theAEDescList, index, &it);
    if (e)
        return e;
    if (theAEKeyword)
        *theAEKeyword = it->key;
    return to_ptr(&it->desc, desiredType, typeCode, dataPtr, maximumSize, actualSize);
}

OSErr
AEGetNthDesc(const AEDescList *theAEDescList, long index, DescType desiredType, AEKeyword *theAEKeyword, AEDesc *result)
{
    struct ae_item *it;
    OSErr e = nth(theAEDescList, index, &it);
    if (e)
        return e;
    if (theAEKeyword)
        *theAEKeyword = it->key;
    return ae_coerce(&it->desc, desiredType, result);
}

OSErr
AESizeOfNthItem(const AEDescList *theAEDescList, long index, DescType *typeCode, Size *dataSize)
{
    struct ae_item *it;
    OSErr e = nth(theAEDescList, index, &it);
    if (e)
        return e;
    if (typeCode)
        *typeCode = it->desc.descriptorType;
    if (dataSize)
        *dataSize = AEGetDescDataSize(&it->desc);
    return noErr;
}

OSErr
AEDeleteItem(AEDescList *theAEDescList, long index)
{
    struct ae_store *s = ae_store(theAEDescList);
    if (!s || s->kind == AE_DATA)
        return errAEWrongDataType;
    if (index < 1 || index > s->items.count)
        return errAEDescNotFound;
    AEDisposeDesc(&s->items.v[index - 1].desc);
    memmove(&s->items.v[index - 1], &s->items.v[index], (s->items.count - index) * sizeof *s->items.v);
    s->items.count--;
    return noErr;
}

static Size
array_item_size(AEArrayType type, Size itemSize)
{
    switch (type) {
    case kAEDataArray:
    case kAEPackedArray: return itemSize;
    case kAEDescArray: return sizeof(AEDesc);
    case kAEKeyDescArray: return sizeof(AEKeyDesc);
    case kAEHandleArray: return sizeof(Handle);
    default: return 0;
    }
}

OSErr
AEPutArray(AEDescList *theAEDescList, AEArrayType arrayType, const AEArrayData *arrayPtr, DescType itemType,
           Size itemSize, long itemCount)
{
    struct ae_store *s = ae_store(theAEDescList);
    if (!s || s->kind == AE_DATA)
        return errAEWrongDataType;
    Size step = array_item_size(arrayType, itemSize);
    if (!step && arrayType != kAEDataArray)
        return errAEBadListItem;
    const unsigned char *p = (const unsigned char *)arrayPtr;
    for (long i = 0; i < itemCount; i++, p += step) {
        OSErr e;
        switch (arrayType) {
        case kAEDataArray:
        case kAEPackedArray: e = AEPutPtr(theAEDescList, 0, itemType, p, itemSize); break;
        case kAEDescArray: e = AEPutDesc(theAEDescList, 0, (const AEDesc *)p); break;
        case kAEKeyDescArray: {
            const AEKeyDesc *kd = (const AEKeyDesc *)p;
            e = AEPutParamDesc(theAEDescList, kd->descKey, &kd->descContent);
            break;
        }
        case kAEHandleArray: {
            Handle h = *(Handle *)p;
            e = AEPutPtr(theAEDescList, 0, itemType, h ? *h : NULL, h ? GetHandleSize(h) : 0);
            break;
        }
        default: e = errAEBadListItem;
        }
        if (e)
            return e;
    }
    return noErr;
}

OSErr
AEGetArray(const AEDescList *theAEDescList, AEArrayType arrayType, AEArrayDataPointer arrayPtr, Size maximumSize,
           DescType *itemType, Size *itemSize, long *itemCount)
{
    struct ae_store *s = ae_store(theAEDescList);
    if (!s || s->kind == AE_DATA)
        return errAEWrongDataType;
    long n = s->items.count;
    Size step = arrayType == kAEDataArray || arrayType == kAEPackedArray
                    ? (n ? AEGetDescDataSize(&s->items.v[0].desc) : 0)
                    : array_item_size(arrayType, 0);
    if (itemType)
        *itemType = n ? s->items.v[0].desc.descriptorType : typeNull;
    if (itemSize)
        *itemSize = step;
    unsigned char *p = (unsigned char *)arrayPtr;
    long done = 0;
    for (long i = 0; i < n && step && (done + 1) * step <= maximumSize; i++, done++, p += step) {
        const AEDesc *d = &s->items.v[i].desc;
        switch (arrayType) {
        case kAEDataArray:
        case kAEPackedArray: AEGetDescData(d, p, step); break;
        case kAEDescArray: AEDuplicateDesc(d, (AEDesc *)p); break;
        case kAEKeyDescArray:
            ((AEKeyDesc *)p)->descKey = s->items.v[i].key;
            AEDuplicateDesc(d, &((AEKeyDesc *)p)->descContent);
            break;
        case kAEHandleArray: {
            Size sz;
            const void *b = ae_bytes(d, &sz);
            PtrToHand(b, (Handle *)p, sz);
            break;
        }
        }
    }
    if (itemCount)
        *itemCount = done;
    return noErr;
}

#pragma mark - Records and Apple event parameters

static OSErr
record_store(const AEDesc *d, struct ae_store **out)
{
    struct ae_store *s = ae_store(d);
    if (!s || (s->kind != AE_RECORD && s->kind != AE_EVENT))
        return errAENotAEDesc;
    *out = s;
    return noErr;
}

OSErr
AEPutParamDesc(AppleEvent *theAppleEvent, AEKeyword theAEKeyword, const AEDesc *theAEDesc)
{
    struct ae_store *s;
    OSErr e = record_store(theAppleEvent, &s);
    return e ? e : ae_items_put(&s->items, theAEKeyword, theAEDesc);
}

OSErr
AEPutParamPtr(AppleEvent *theAppleEvent, AEKeyword theAEKeyword, DescType typeCode, const void *dataPtr, Size dataSize)
{
    struct ae_store *s;
    OSErr e = record_store(theAppleEvent, &s);
    if (e)
        return e;
    AEDesc d;
    if ((e = ae_make_data(typeCode, dataPtr, dataSize, &d)))
        return e;
    e = ae_items_put(&s->items, theAEKeyword, &d);
    AEDisposeDesc(&d);
    return e;
}

static OSErr
param(const AppleEvent *ae, AEKeyword key, struct ae_item **out)
{
    struct ae_store *s;
    OSErr e = record_store(ae, &s);
    if (e)
        return e;
    *out = ae_find(&s->items, key);
    return *out ? noErr : errAEDescNotFound;
}

OSErr
AEGetParamPtr(const AppleEvent *theAppleEvent, AEKeyword theAEKeyword, DescType desiredType, DescType *actualType,
              void *dataPtr, Size maximumSize, Size *actualSize)
{
    struct ae_item *it;
    OSErr e = param(theAppleEvent, theAEKeyword, &it);
    return e ? e : to_ptr(&it->desc, desiredType, actualType, dataPtr, maximumSize, actualSize);
}

OSErr
AEGetParamDesc(const AppleEvent *theAppleEvent, AEKeyword theAEKeyword, DescType desiredType, AEDesc *result)
{
    struct ae_item *it;
    OSErr e = param(theAppleEvent, theAEKeyword, &it);
    if (e) {
        if (result)
            AEInitializeDesc(result);
        return e;
    }
    return ae_coerce(&it->desc, desiredType, result);
}

OSErr
AESizeOfParam(const AppleEvent *theAppleEvent, AEKeyword theAEKeyword, DescType *typeCode, Size *dataSize)
{
    struct ae_item *it;
    OSErr e = param(theAppleEvent, theAEKeyword, &it);
    if (e)
        return e;
    if (typeCode)
        *typeCode = it->desc.descriptorType;
    if (dataSize)
        *dataSize = AEGetDescDataSize(&it->desc);
    return noErr;
}

OSErr
AEDeleteParam(AppleEvent *theAppleEvent, AEKeyword theAEKeyword)
{
    struct ae_store *s;
    OSErr e = record_store(theAppleEvent, &s);
    if (e)
        return e;
    struct ae_item *it = ae_find(&s->items, theAEKeyword);
    if (!it)
        return errAEDescNotFound;
    long i = it - s->items.v;
    AEDisposeDesc(&it->desc);
    memmove(&s->items.v[i], &s->items.v[i + 1], (s->items.count - i - 1) * sizeof *s->items.v);
    s->items.count--;
    return noErr;
}

#pragma mark - Apple events and attributes

OSErr
AECreateAppleEvent(AEEventClass theAEEventClass, AEEventID theAEEventID, const AEAddressDesc *target,
                   AEReturnID returnID, AETransactionID transactionID, AppleEvent *result)
{
    if (!result)
        return paramErr;
    OSErr e = ae_make_container(typeAppleEvent, AE_EVENT, result);
    if (e)
        return e;
    struct ae_store *s = ae_store(result);
    SInt32 rid = returnID == kAutoGenerateReturnID ? ae_next_return_id() : returnID;
    SInt32 tid = transactionID, inte = 0x70, timo = 0;
    SInt16 esrc = kAELocalProcess;
    ProcessSerialNumber from = {0, kCurrentProcess};
    struct {
        AEKeyword key;
        DescType type;
        const void *p;
        Size n;
    } attrs[] = {
        {keyEventClassAttr, typeType, &theAEEventClass, 4},
        {keyEventIDAttr, typeType, &theAEEventID, 4},
        {keyReturnIDAttr, typeSInt32, &rid, 4},
        {keyTransactionIDAttr, typeSInt32, &tid, 4},
        {keyEventSourceAttr, typeSInt16, &esrc, 2},
        {keyInteractLevelAttr, typeSInt32, &inte, 4},
        {keyTimeoutAttr, typeSInt32, &timo, 4},
        {keyOriginalAddressAttr, typeProcessSerialNumber, &from, sizeof from},
    };
    for (size_t i = 0; i < sizeof attrs / sizeof *attrs && !e; i++) {
        AEDesc d;
        if (!(e = ae_make_data(attrs[i].type, attrs[i].p, attrs[i].n, &d))) {
            e = ae_items_put(&s->attrs, attrs[i].key, &d);
            AEDisposeDesc(&d);
        }
        if (!e && i == 1) {  /* the address goes third, as Apple's */
            AEDesc none = {typeNull, NULL};
            e = ae_items_put(&s->attrs, keyAddressAttr, target ? target : &none);
        }
    }
    if (e)
        AEDisposeDesc(result);
    return e;
}

static OSErr
event_store(const AEDesc *d, struct ae_store **out)
{
    struct ae_store *s = ae_store(d);
    if (!s || s->kind == AE_DATA || s->kind == AE_LIST)
        return errAENotAEDesc;
    if (s->kind != AE_EVENT)
        return paramErr;
    *out = s;
    return noErr;
}

static OSErr
attribute(const AppleEvent *ae, AEKeyword key, struct ae_item **out)
{
    struct ae_store *s;
    OSErr e = event_store(ae, &s);
    if (e)
        return e;
    *out = ae_find(&s->attrs, key);
    return *out ? noErr : errAEDescNotFound;
}

OSErr
AEPutAttributeDesc(AppleEvent *theAppleEvent, AEKeyword theAEKeyword, const AEDesc *theAEDesc)
{
    struct ae_store *s;
    OSErr e = event_store(theAppleEvent, &s);
    if (e)
        return e;
    switch (theAEKeyword) {
    case keyEventClassAttr:
    case keyEventIDAttr: {
        /* stored as type codes */
        AEDesc t;
        if ((e = ae_coerce(theAEDesc, typeType, &t)))
            return e;
        e = ae_items_put(&s->attrs, theAEKeyword, &t);
        AEDisposeDesc(&t);
        return e;
    }
    case keyOriginalAddressAttr:
        if (theAEDesc->descriptorType != typeProcessSerialNumber)
            return errAECoercionFail;
        break;
    case 'tbsc':
        return errAECoercionFail;
    }
    return ae_items_put(&s->attrs, theAEKeyword, theAEDesc);
}

OSErr
AEPutAttributePtr(AppleEvent *theAppleEvent, AEKeyword theAEKeyword, DescType typeCode, const void *dataPtr,
                  Size dataSize)
{
    AEDesc d;
    OSErr e = ae_make_data(typeCode, dataPtr, dataSize, &d);
    if (e)
        return e;
    e = AEPutAttributeDesc(theAppleEvent, theAEKeyword, &d);
    AEDisposeDesc(&d);
    return e;
}

OSErr
AEGetAttributePtr(const AppleEvent *theAppleEvent, AEKeyword theAEKeyword, DescType desiredType, DescType *typeCode,
                  void *dataPtr, Size maximumSize, Size *actualSize)
{
    struct ae_item *it;
    OSErr e = attribute(theAppleEvent, theAEKeyword, &it);
    return e ? e : to_ptr(&it->desc, desiredType, typeCode, dataPtr, maximumSize, actualSize);
}

OSErr
AEGetAttributeDesc(const AppleEvent *theAppleEvent, AEKeyword theAEKeyword, DescType desiredType, AEDesc *result)
{
    struct ae_item *it;
    OSErr e = attribute(theAppleEvent, theAEKeyword, &it);
    if (e) {
        if (result)
            AEInitializeDesc(result);
        return e;
    }
    return ae_coerce(&it->desc, desiredType, result);
}

OSErr
AESizeOfAttribute(const AppleEvent *theAppleEvent, AEKeyword theAEKeyword, DescType *typeCode, Size *dataSize)
{
    struct ae_item *it;
    OSErr e = attribute(theAppleEvent, theAEKeyword, &it);
    if (e)
        return e;
    if (typeCode)
        *typeCode = it->desc.descriptorType;
    if (dataSize)
        *dataSize = AEGetDescDataSize(&it->desc);
    return noErr;
}

#pragma mark - Comparing

/* Equal descriptors: same type and bytes, or same items. */
static bool
same(const AEDesc *a, const AEDesc *b)
{
    if (a->descriptorType != b->descriptorType)
        return false;
    struct ae_store *x = ae_store(a), *y = ae_store(b);
    if (!x || !y)
        return !x && !y;
    if (x->kind != y->kind)
        return false;
    if (x->kind == AE_DATA)
        return x->size == y->size && !memcmp(x + 1, y + 1, x->size);
    if (x->items.count != y->items.count)
        return false;
    for (long i = 0; i < x->items.count; i++)
        if (x->items.v[i].key != y->items.v[i].key || !same(&x->items.v[i].desc, &y->items.v[i].desc))
            return false;
    return true;
}

FINCH_HIDDEN bool
ae_same(const AEDesc *a, const AEDesc *b)
{
    return same(a, b);
}
