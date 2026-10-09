/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The Memory Manager's handles and pointers, over malloc. A Handle points at
 * a master pointer, the first field of a block that also holds the size and
 * the lock/purge state; *h is the data (NULL once emptied). Pointers carry
 * their size in a header just before the data. MemError reports the last
 * call's result, per thread.
 */
#include "CarbonCore_Finch.h"
#include <malloc/malloc.h>

#define HMAGIC 0x466e4864u /* 'FnHd' */
#define PMAGIC 0x466e5074u /* 'FnPt' */

struct hblock {
    char *master;  /* must stay first: a Handle is &master */
    Size size;
    uint32_t magic;
    SInt8 state;   /* the HGetState bits: 0x80 locked, 0x40 purgeable, 0x20 resource */
};

struct pheader {
    Size size;
    uint32_t magic;
    uint32_t pad;
};

static __thread OSErr mem_err;

static void
set_err(OSErr e)
{
    mem_err = e;
}

FINCH_HIDDEN struct hblock *
_hblock(Handle h)
{
    struct hblock *b = (struct hblock *)h;
    return (b && b->magic == HMAGIC) ? b : NULL;
}

OSErr MemError(void) { return mem_err; }
SInt16 LMGetMemErr(void) { return mem_err; }
void LMSetMemErr(SInt16 value) { mem_err = value; }

static Handle
new_handle(Size size, bool clear, bool empty)
{
    if (size < 0) {
        set_err(memSCErr);
        return NULL;
    }
    struct hblock *b = calloc(1, sizeof *b);
    if (!b) {
        set_err(memFullErr);
        return NULL;
    }
    b->magic = HMAGIC;
    if (!empty) {
        b->master = clear ? calloc(1, size ? size : 1) : malloc(size ? size : 1);
        if (!b->master) {
            free(b);
            set_err(memFullErr);
            return NULL;
        }
        b->size = size;
    }
    set_err(noErr);
    return (Handle)&b->master;
}

Handle NewHandle(Size byteCount) { return new_handle(byteCount, false, false); }
Handle NewHandleClear(Size byteCount) { return new_handle(byteCount, true, false); }
Handle NewEmptyHandle(void) { return new_handle(0, false, true); }
Handle TempNewHandle(Size logicalSize, OSErr *resultCode)
{
    Handle h = NewHandle(logicalSize);
    if (resultCode)
        *resultCode = mem_err;
    return h;
}

void
DisposeHandle(Handle h)
{
    struct hblock *b = _hblock(h);
    if (!b) {
        set_err(h ? nilHandleErr : noErr);
        return;
    }
    free(b->master);
    b->magic = 0;
    free(b);
    set_err(noErr);
}

void TempDisposeHandle(Handle h, OSErr *resultCode)
{
    DisposeHandle(h);
    if (resultCode)
        *resultCode = mem_err;
}

Size
GetHandleSize(Handle h)
{
    struct hblock *b = _hblock(h);
    if (!b) {
        set_err(nilHandleErr);
        return 0;
    }
    set_err(noErr);
    return b->master ? b->size : 0;
}

void
SetHandleSize(Handle h, Size newSize)
{
    struct hblock *b = _hblock(h);
    if (!b) {
        set_err(nilHandleErr);
        return;
    }
    if (newSize < 0) {
        set_err(memSCErr);
        return;
    }
    char *p = realloc(b->master, newSize ? newSize : 1);
    if (!p) {
        set_err(memFullErr);
        return;
    }
    b->master = p;
    b->size = newSize;
    set_err(noErr);
}

void
EmptyHandle(Handle h)
{
    struct hblock *b = _hblock(h);
    if (!b) {
        set_err(nilHandleErr);
        return;
    }
    free(b->master);
    b->master = NULL;
    b->size = 0;
    set_err(noErr);
}

void
ReallocateHandle(Handle h, Size byteCount)
{
    struct hblock *b = _hblock(h);
    if (!b) {
        set_err(nilHandleErr);
        return;
    }
    free(b->master);
    b->master = malloc(byteCount ? byteCount : 1);
    b->size = b->master ? byteCount : 0;
    set_err(b->master ? noErr : memFullErr);
}

Handle
RecoverHandle(Ptr p)
{
    set_err(memAZErr);  /* a master pointer isn't findable from its data */
    return NULL;
}

void HLock(Handle h) { struct hblock *b = _hblock(h); if (b) b->state |= 0x80; set_err(b ? noErr : nilHandleErr); }
void HLockHi(Handle h) { HLock(h); }
void HUnlock(Handle h) { struct hblock *b = _hblock(h); if (b) b->state &= ~0x80; set_err(b ? noErr : nilHandleErr); }
void HPurge(Handle h) { struct hblock *b = _hblock(h); if (b) b->state |= 0x40; set_err(b ? noErr : nilHandleErr); }
void HNoPurge(Handle h) { struct hblock *b = _hblock(h); if (b) b->state &= ~0x40; set_err(b ? noErr : nilHandleErr); }
void HSetRBit(Handle h) { struct hblock *b = _hblock(h); if (b) b->state |= 0x20; set_err(b ? noErr : nilHandleErr); }
void HClrRBit(Handle h) { struct hblock *b = _hblock(h); if (b) b->state &= ~0x20; set_err(b ? noErr : nilHandleErr); }
SInt8 HGetState(Handle h) { struct hblock *b = _hblock(h); set_err(b ? noErr : nilHandleErr); return b ? b->state : 0; }
void HSetState(Handle h, SInt8 flags) { struct hblock *b = _hblock(h); if (b) b->state = flags; set_err(b ? noErr : nilHandleErr); }
void TempHLock(Handle h, OSErr *resultCode) { HLock(h); if (resultCode) *resultCode = mem_err; }
void TempHUnlock(Handle h, OSErr *resultCode) { HUnlock(h); if (resultCode) *resultCode = mem_err; }
void MoveHHi(Handle h) { set_err(_hblock(h) ? noErr : nilHandleErr); }
void MoreMasters(void) {}
void MoreMasterPointers(UInt32 inCount) {}
Boolean IsHandleValid(Handle h) { return _hblock(h) != NULL; }

OSErr
PtrToHand(const void *srcPtr, Handle *dstHndl, long size)
{
    Handle h = NewHandle(size);
    if (!h) {
        *dstHndl = NULL;
        return mem_err;
    }
    if (size)
        memcpy(*h, srcPtr, size);
    *dstHndl = h;
    return noErr;
}

OSErr
PtrToXHand(const void *srcPtr, Handle dstHndl, long size)
{
    SetHandleSize(dstHndl, size);
    if (mem_err)
        return mem_err;
    if (size)
        memcpy(*dstHndl, srcPtr, size);
    return noErr;
}

OSErr
HandToHand(Handle *theHndl)
{
    Handle src = *theHndl;
    Size n = GetHandleSize(src);
    if (mem_err)
        return mem_err;
    return PtrToHand(*src, theHndl, n);
}

OSErr
PtrAndHand(const void *ptr1, Handle hand2, long size)
{
    Size n = GetHandleSize(hand2);
    if (mem_err)
        return mem_err;
    SetHandleSize(hand2, n + size);
    if (mem_err)
        return mem_err;
    if (size)
        memmove(*hand2 + n, ptr1, size);
    return noErr;
}

OSErr
HandAndHand(Handle hand1, Handle hand2)
{
    Size n = GetHandleSize(hand1);
    if (mem_err)
        return mem_err;
    /* hand1 may be hand2 */
    void *copy = malloc(n ? n : 1);
    memcpy(copy, *hand1, n);
    OSErr e = PtrAndHand(copy, hand2, n);
    free(copy);
    return e;
}

static Ptr
new_ptr(Size size, bool clear)
{
    if (size < 0) {
        set_err(memSCErr);
        return NULL;
    }
    struct pheader *p = clear ? calloc(1, sizeof *p + size) : malloc(sizeof *p + size);
    if (!p) {
        set_err(memFullErr);
        return NULL;
    }
    p->size = size;
    p->magic = PMAGIC;
    set_err(noErr);
    return (Ptr)(p + 1);
}

static struct pheader *
pheader(Ptr p)
{
    if (!p)
        return NULL;
    struct pheader *h = (struct pheader *)p - 1;
    return h->magic == PMAGIC ? h : NULL;
}

Ptr NewPtr(Size byteCount) { return new_ptr(byteCount, false); }
Ptr NewPtrClear(Size byteCount) { return new_ptr(byteCount, true); }

void
DisposePtr(Ptr p)
{
    struct pheader *h = pheader(p);
    if (h) {
        h->magic = 0;
        free(h);
    }
    set_err(noErr);
}

Size
GetPtrSize(Ptr p)
{
    struct pheader *h = pheader(p);
    set_err(h ? noErr : memWZErr);
    return h ? h->size : 0;
}

void
SetPtrSize(Ptr p, Size newSize)
{
    struct pheader *h = pheader(p);
    if (!h) {
        set_err(memWZErr);
        return;
    }
    if (newSize > h->size) {
        set_err(memFullErr);  /* a pointer can't move */
        return;
    }
    h->size = newSize;
    set_err(noErr);
}

Boolean IsPointerValid(Ptr p) { return pheader(p) != NULL; }
Boolean IsHeapValid(void) { return true; }
Boolean CheckAllHeaps(void) { return true; }
long FreeMem(void) { return 0x7fffffff; }
Size MaxMem(Size *grow) { if (grow) *grow = 0; return 0x7fffffff; }
Size CompactMem(Size cbNeeded) { return 0x7fffffff; }
void PurgeMem(Size cbNeeded) {}
long TempFreeMem(void) { return 0x7fffffff; }
Size TempMaxMem(Size *grow) { if (grow) *grow = 0; return 0x7fffffff; }
void ReserveMem(Size cbNeeded) {}
void PurgeSpace(long *total, long *contig) { if (total) *total = 0x7fffffff; if (contig) *contig = 0x7fffffff; }
long PurgeSpaceTotal(void) { return 0x7fffffff; }
long PurgeSpaceContiguous(void) { return 0x7fffffff; }
OSErr HoldMemory(void *address, unsigned long count) { return noErr; }
OSErr UnholdMemory(void *address, unsigned long count) { return noErr; }
OSErr MakeMemoryResident(void *address, unsigned long count) { return noErr; }
OSErr ReleaseMemoryData(void *address, unsigned long count) { return noErr; }
OSErr MakeMemoryNonResident(void *address, unsigned long count) { return noErr; }
OSErr FlushMemory(void *address, unsigned long count) { return noErr; }

