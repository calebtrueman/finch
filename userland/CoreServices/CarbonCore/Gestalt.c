/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Gestalt (Gestalt.h): the system version from kern.osproductversion
 * ('sysv' packs it as macOS does, 26.4.1 -> 0x2641, each part capped at 9
 * past the major), memory from hw.memsize, and the fixed answers macOS 26
 * gives for the selectors apps still ask (processor family, page size,
 * Alias/File/Resource Manager attributes). Apps can add selectors.
 */
#include "CarbonCore_Finch.h"
#include <pthread.h>
#include <sys/sysctl.h>
#include <unistd.h>

struct selector {
    OSType sel;
    SelectorFunctionUPP proc;
    SInt32 value;
    bool isValue;
};

static struct selector *custom;
static long ncustom;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static void
os_version(int v[3])
{
    char s[64] = {0};
    size_t n = sizeof s - 1;
    v[0] = v[1] = v[2] = 0;
    if (sysctlbyname("kern.osproductversion", s, &n, NULL, 0) == 0)
        sscanf(s, "%d.%d.%d", &v[0], &v[1], &v[2]);
    if (!v[0])
        v[0] = 26;
}

static bool
builtin(OSType selector, SInt32 *r)
{
    int v[3];
    uint64_t mem = 0;
    size_t n = sizeof mem;
    switch (selector) {
    case gestaltSystemVersion:
        os_version(v);
        *r = (v[0] / 10) << 12 | (v[0] % 10) << 8 | (v[1] > 9 ? 9 : v[1]) << 4 | (v[2] > 9 ? 9 : v[2]);
        return true;
    case gestaltSystemVersionMajor: os_version(v); *r = v[0]; return true;
    case gestaltSystemVersionMinor: os_version(v); *r = v[1]; return true;
    case gestaltSystemVersionBugFix: os_version(v); *r = v[2]; return true;
    case gestaltPhysicalRAMSize:
    case gestaltLogicalRAMSize:
        sysctlbyname("hw.memsize", &mem, &n, NULL, 0);
        if (selector == gestaltLogicalRAMSize)
            *r = mem > 0x7ffff000ULL ? 0x7ffff000 : (SInt32)mem;
        else
            *r = mem > 0x7fffffffULL ? 0x7fffffff : (SInt32)mem;
        return true;
    case gestaltLogicalPageSize: *r = (SInt32)getpagesize(); return true;
    case 'cput': *r = 'ax64'; return true;
    case 'cpuf': *r = 'arm '; return true;
    case gestaltSysArchitecture: *r = 0x14; return true;  /* 'sysa' */
    case gestaltVMAttr: *r = 0x11; return true;
    case gestaltOSAttr: *r = 0xfe; return true;
    case gestaltAliasMgrAttr: *r = 0x1c9; return true;
    case gestaltFSAttr: *r = 0x3d332; return true;
    case gestaltThreadMgrAttr: *r = 0x7; return true;
    case gestaltCFMAttr: *r = 0x1; return true;
    case gestaltResourceMgrAttr: *r = 0x3; return true;
    case gestaltHelpMgrAttr: *r = 0; return true;
    }
    return false;
}

OSErr
Gestalt(OSType selector, SInt32 *response)
{
    SInt32 r = 0;
    pthread_mutex_lock(&lock);
    for (long i = 0; i < ncustom; i++)
        if (custom[i].sel == selector) {
            struct selector s = custom[i];
            pthread_mutex_unlock(&lock);
            if (s.isValue)
                r = s.value;
            else {
                OSErr e = s.proc(selector, &r);
                if (e)
                    return e;
            }
            if (response)
                *response = r;
            return noErr;
        }
    pthread_mutex_unlock(&lock);
    if (!builtin(selector, &r))
        return gestaltUndefSelectorErr;
    if (response)
        *response = r;
    return noErr;
}

static OSErr
put(OSType selector, SelectorFunctionUPP proc, SInt32 value, bool isValue, bool mustExist, bool mustNotExist,
    SelectorFunctionUPP *old)
{
    pthread_mutex_lock(&lock);
    struct selector *s = NULL;
    for (long i = 0; i < ncustom; i++)
        if (custom[i].sel == selector)
            s = &custom[i];
    SInt32 dummy;
    bool exists = s || builtin(selector, &dummy);
    OSErr e = noErr;
    if (mustExist && !exists)
        e = gestaltUndefSelectorErr;
    else if (mustNotExist && exists)
        e = gestaltDupSelectorErr;
    else {
        if (!s) {
            custom = realloc(custom, (ncustom + 1) * sizeof *custom);
            s = &custom[ncustom++];
        }
        if (old)
            *old = s->proc;
        *s = (struct selector){selector, proc, value, isValue};
    }
    pthread_mutex_unlock(&lock);
    return e;
}

OSErr NewGestalt(OSType selector, SelectorFunctionUPP gestaltFunction) { return put(selector, gestaltFunction, 0, false, false, true, NULL); }
OSErr ReplaceGestalt(OSType selector, SelectorFunctionUPP gestaltFunction, SelectorFunctionUPP *oldGestaltFunction)
{
    return put(selector, gestaltFunction, 0, false, true, false, oldGestaltFunction);
}
OSErr NewGestaltValue(OSType selector, SInt32 newValue) { return put(selector, NULL, newValue, true, false, true, NULL); }
OSErr ReplaceGestaltValue(OSType selector, SInt32 replacementValue) { return put(selector, NULL, replacementValue, true, true, false, NULL); }
OSErr SetGestaltValue(OSType selector, SInt32 newValue) { return put(selector, NULL, newValue, true, false, false, NULL); }

OSErr
DeleteGestaltValue(OSType selector)
{
    pthread_mutex_lock(&lock);
    OSErr e = gestaltUndefSelectorErr;
    for (long i = 0; i < ncustom; i++)
        if (custom[i].sel == selector) {
            memmove(&custom[i], &custom[i + 1], (ncustom - i - 1) * sizeof *custom);
            ncustom--;
            e = noErr;
            break;
        }
    pthread_mutex_unlock(&lock);
    return e;
}

SelectorFunctionUPP (NewSelectorFunctionUPP)(SelectorFunctionProcPtr userRoutine) { return userRoutine; }
void (DisposeSelectorFunctionUPP)(SelectorFunctionUPP userUPP) {}
OSErr (InvokeSelectorFunctionUPP)(OSType selector, SInt32 *response, SelectorFunctionUPP userUPP)
{
    return userUPP(selector, response);
}
