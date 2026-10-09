/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* CF runtime registration for CoreText's types (CTInternal.h). */
#include "CTInternal.h"
#include <pthread.h>
#include <string.h>

static pthread_mutex_t register_lock = PTHREAD_MUTEX_INITIALIZER;

CFTypeID
CTTypeRegister(const CTRuntimeClass *cls, CFTypeID *slot)
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
CTTypeCreateInstance(CFTypeID type, size_t size)
{
    void *obj = (void *)_CFRuntimeCreateInstance(NULL, type, (CFIndex)(size - sizeof(CTRuntimeBase)), NULL);
    if (obj)
        memset((char *)obj + sizeof(CTRuntimeBase), 0, size - sizeof(CTRuntimeBase));
    return obj;
}
