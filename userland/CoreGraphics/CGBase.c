/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CF runtime registration for CG's types (CGInternal.h). */
#include "CGInternal.h"
#include <pthread.h>
#include <string.h>

static pthread_mutex_t register_lock = PTHREAD_MUTEX_INITIALIZER;

CFTypeID
CGTypeRegister(const CGRuntimeClass *cls, CFTypeID *slot)
{
    CFTypeID id = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
    if (id)
        return id;
    pthread_mutex_lock(&register_lock);
    id = __atomic_load_n(slot, __ATOMIC_RELAXED);
    if (!id) {
        id = _CFRuntimeRegisterClass(cls);
        __atomic_store_n(slot, id, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&register_lock);
    return id;
}

void *
CGTypeCreateInstance(CFTypeID type, size_t size)
{
    void *obj = (void *)_CFRuntimeCreateInstance(NULL, type, size - sizeof(CGRuntimeBase), NULL);
    if (obj)
        memset((char *)obj + sizeof(CGRuntimeBase), 0, size - sizeof(CGRuntimeBase));
    return obj;
}

CFStringRef
CGTypeCopyDescriptionPrefix(CFTypeRef cf, const char *name)
{
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("<%s %p>"), name, cf);
}

/* The mouse's movement since the last mouse event (CGRemoteOperation.h). Finch reports none yet. */
__attribute__((visibility("default"))) void
CGGetLastMouseDelta(int32_t *deltaX, int32_t *deltaY)
{
    if (deltaX)
        *deltaX = 0;
    if (deltaY)
        *deltaY = 0;
}
