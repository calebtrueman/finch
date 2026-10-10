/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * HIToolbox's Carbon events (CarbonEventsCore.h): events as Apple's are, a
 * class, a kind, a time (seconds since startup), attributes and named, typed
 * parameters, reference counted. Apps make them to hand to the Carbon calls
 * that still take them (Terminal translates keys through
 * TSMProcessRawKeyCode with one); there is no Carbon event loop.
 */
#include <Carbon/Carbon.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct Param {
    EventParamName name;
    EventParamType type;
    ByteCount size;
    void *data;
} Param;

struct OpaqueEventRef {
    pthread_mutex_t lock;
    ItemCount refs;
    OSType event_class;
    UInt32 kind;
    EventTime when;
    EventAttributes attributes;
    Param *params;
    size_t count, capacity;
};

EventTime
GetCurrentEventTime(void)
{
    return (EventTime)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

/* CreateEvent (the header's MacCreateEvent) */
OSStatus
MacCreateEvent(CFAllocatorRef inAllocator, OSType inClassID, UInt32 inKind, EventTime inWhen, EventAttributes inAttributes,
               EventRef *outEvent)
{
    if (!outEvent)
        return paramErr;
    EventRef e = calloc(1, sizeof *e);
    if (!e)
        return memFullErr;
    pthread_mutex_init(&e->lock, NULL);
    e->refs = 1;
    e->event_class = inClassID;
    e->kind = inKind;
    e->when = inWhen ? inWhen : GetCurrentEventTime();
    e->attributes = inAttributes;
    *outEvent = e;
    return noErr;
}

static Param *
find(EventRef e, EventParamName name)
{
    for (size_t i = 0; i < e->count; i++)
        if (e->params[i].name == name)
            return &e->params[i];
    return NULL;
}

OSStatus
SetEventParameter(EventRef inEvent, EventParamName inName, EventParamType inType, ByteCount inSize, const void *inDataPtr)
{
    if (!inEvent || (inSize && !inDataPtr))
        return paramErr;
    void *copy = malloc(inSize ? inSize : 1);
    if (!copy)
        return memFullErr;
    if (inSize)
        memcpy(copy, inDataPtr, inSize);
    pthread_mutex_lock(&inEvent->lock);
    Param *p = find(inEvent, inName);
    if (p) {
        free(p->data);
    } else {
        if (inEvent->count == inEvent->capacity) {
            size_t cap = inEvent->capacity ? inEvent->capacity * 2 : 8;
            Param *grown = realloc(inEvent->params, cap * sizeof *grown);
            if (!grown) {
                pthread_mutex_unlock(&inEvent->lock);
                free(copy);
                return memFullErr;
            }
            inEvent->params = grown;
            inEvent->capacity = cap;
        }
        p = &inEvent->params[inEvent->count++];
        p->name = inName;
    }
    p->type = inType;
    p->size = inSize;
    p->data = copy;
    pthread_mutex_unlock(&inEvent->lock);
    return noErr;
}

OSStatus
GetEventParameter(EventRef inEvent, EventParamName inName, EventParamType inDesiredType, EventParamType *outActualType,
                  ByteCount inBufferSize, ByteCount *outActualSize, void *outData)
{
    if (!inEvent)
        return paramErr;
    pthread_mutex_lock(&inEvent->lock);
    Param *p = find(inEvent, inName);
    if (!p) {
        pthread_mutex_unlock(&inEvent->lock);
        return eventParameterNotFoundErr;
    }
    /* typeWildCard takes it as it is; other types must match (no coercion here) */
    if (inDesiredType != typeWildCard && inDesiredType != p->type) {
        pthread_mutex_unlock(&inEvent->lock);
        return errAECoercionFail;
    }
    if (outActualType)
        *outActualType = p->type;
    if (outActualSize)
        *outActualSize = p->size;
    if (outData)
        memcpy(outData, p->data, p->size < inBufferSize ? p->size : inBufferSize);
    pthread_mutex_unlock(&inEvent->lock);
    return noErr;
}

OSStatus
RemoveEventParameter(EventRef inEvent, EventParamName inName)
{
    if (!inEvent)
        return paramErr;
    pthread_mutex_lock(&inEvent->lock);
    Param *p = find(inEvent, inName);
    if (!p) {
        pthread_mutex_unlock(&inEvent->lock);
        return eventParameterNotFoundErr;
    }
    free(p->data);
    *p = inEvent->params[--inEvent->count];
    pthread_mutex_unlock(&inEvent->lock);
    return noErr;
}

EventRef
RetainEvent(EventRef inEvent)
{
    if (inEvent) {
        pthread_mutex_lock(&inEvent->lock);
        inEvent->refs++;
        pthread_mutex_unlock(&inEvent->lock);
    }
    return inEvent;
}

ItemCount
GetEventRetainCount(EventRef inEvent)
{
    return inEvent ? inEvent->refs : 0;
}

void
ReleaseEvent(EventRef inEvent)
{
    if (!inEvent)
        return;
    pthread_mutex_lock(&inEvent->lock);
    ItemCount left = --inEvent->refs;
    pthread_mutex_unlock(&inEvent->lock);
    if (left)
        return;
    for (size_t i = 0; i < inEvent->count; i++)
        free(inEvent->params[i].data);
    free(inEvent->params);
    pthread_mutex_destroy(&inEvent->lock);
    free(inEvent);
}

EventRef
CopyEvent(EventRef inOther)
{
    if (!inOther)
        return NULL;
    EventRef e;
    if (MacCreateEvent(NULL, inOther->event_class, inOther->kind, inOther->when, inOther->attributes, &e) != noErr)
        return NULL;
    pthread_mutex_lock(&inOther->lock);
    for (size_t i = 0; i < inOther->count; i++) {
        Param *p = &inOther->params[i];
        SetEventParameter(e, p->name, p->type, p->size, p->data);
    }
    pthread_mutex_unlock(&inOther->lock);
    return e;
}

EventRef
CopyEventAs(CFAllocatorRef inAllocator, EventRef inOther, OSType inEventClass, UInt32 inEventKind)
{
    EventRef e = CopyEvent(inOther);
    if (e)
        e->event_class = inEventClass, e->kind = inEventKind;
    return e;
}

OSType GetEventClass(EventRef inEvent) { return inEvent ? inEvent->event_class : 0; }
UInt32 GetEventKind(EventRef inEvent) { return inEvent ? inEvent->kind : 0; }
EventTime GetEventTime(EventRef inEvent) { return inEvent ? inEvent->when : 0; }

OSStatus
SetEventTime(EventRef inEvent, EventTime inTime)
{
    if (!inEvent)
        return paramErr;
    inEvent->when = inTime;
    return noErr;
}

Boolean
IsEventInQueue(EventQueueRef inQueue, EventRef inEvent)
{
    return false;
}
