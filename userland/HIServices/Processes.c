/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The Process Manager (Processes.h): process serial numbers over BSD processes. A PSN
 * is {1, pid} (or Apple's constants: kNoProcess, kSystemProcess, kCurrentProcess).
 * Bringing apps forward and hiding them is the window server's and AppKit's business
 * on Finch; those calls succeed and leave it to them.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static pid_t
psn_pid(const ProcessSerialNumber *psn)
{
    if (!psn)
        return -1;
    if (psn->highLongOfPSN == 0 && psn->lowLongOfPSN == kCurrentProcess)
        return getpid();
    if (psn->highLongOfPSN == 1)
        return (pid_t)psn->lowLongOfPSN;
    return -1;
}

static void
psn_set(ProcessSerialNumber *psn, pid_t pid)
{
    psn->highLongOfPSN = 1;
    psn->lowLongOfPSN = (UInt32)pid;
}

static bool
alive(pid_t pid)
{
    return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
}

OSErr
GetCurrentProcess(ProcessSerialNumber *pPSN)
{
    if (!pPSN)
        return paramErr;
    psn_set(pPSN, getpid());
    return noErr;
}

OSErr
GetFrontProcess(ProcessSerialNumber *pPSN)
{
    /* the front app is the window server's to say; until it's asked, this one */
    return GetCurrentProcess(pPSN);
}

static int
compare_pids(const void *a, const void *b)
{
    return *(const pid_t *)a - *(const pid_t *)b;
}

OSErr
GetNextProcess(ProcessSerialNumber *pPSN)
{
    if (!pPSN)
        return paramErr;
    pid_t after = (pPSN->highLongOfPSN == 0 && pPSN->lowLongOfPSN == kNoProcess) ? 0 : psn_pid(pPSN);
    if (after < 0)
        return procNotFound;
    int n = proc_listallpids(NULL, 0);
    if (n <= 0)
        return procNotFound;
    pid_t *pids = calloc((size_t)n + 16, sizeof(pid_t));
    n = proc_listallpids(pids, (int)((size_t)(n + 16) * sizeof(pid_t)));
    qsort(pids, (size_t)n, sizeof(pid_t), compare_pids);
    OSErr err = procNotFound;
    for (int i = 0; i < n; i++)
        if (pids[i] > after) {
            psn_set(pPSN, pids[i]);
            err = noErr;
            break;
        }
    free(pids);
    if (err)
        pPSN->highLongOfPSN = 0, pPSN->lowLongOfPSN = kNoProcess;
    return err;
}

OSStatus
GetProcessPID(const ProcessSerialNumber *psn, pid_t *pid)
{
    pid_t p = psn_pid(psn);
    if (!pid)
        return paramErr;
    if (p < 0 || !alive(p))
        return procNotFound;
    *pid = p;
    return noErr;
}

OSStatus
GetProcessForPID(pid_t pid, ProcessSerialNumber *psn)
{
    if (!psn)
        return paramErr;
    if (!alive(pid))
        return procNotFound;
    psn_set(psn, pid);
    return noErr;
}

OSErr
SameProcess(const ProcessSerialNumber *PSN1, const ProcessSerialNumber *PSN2, Boolean *result)
{
    if (!result)
        return paramErr;
    pid_t a = psn_pid(PSN1), b = psn_pid(PSN2);
    if (a < 0 || b < 0)
        return procNotFound;
    *result = a == b;
    return noErr;
}

OSStatus
CopyProcessName(const ProcessSerialNumber *psn, CFStringRef *name)
{
    pid_t pid = psn_pid(psn);
    if (!name)
        return paramErr;
    if (pid < 0 || !alive(pid))
        return procNotFound;
    if (pid == getpid()) {
        CFBundleRef main = CFBundleGetMainBundle();
        CFTypeRef n = main ? CFBundleGetValueForInfoDictionaryKey(main, kCFBundleNameKey) : NULL;
        if (n && CFGetTypeID(n) == CFStringGetTypeID()) {
            *name = CFRetain(n);
            return noErr;
        }
    }
    char buf[2 * MAXCOMLEN + 1] = "";
    proc_name(pid, buf, sizeof buf);
    *name = CFStringCreateWithCString(NULL, buf, kCFStringEncodingUTF8);
    return noErr;
}

CFDictionaryRef
ProcessInformationCopyDictionary(const ProcessSerialNumber *PSN, UInt32 infoToReturn)
{
    pid_t pid = psn_pid(PSN);
    if (pid < 0 || !alive(pid))
        return NULL;
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);
    long long pid64 = pid;
    CFNumberRef n = CFNumberCreate(NULL, kCFNumberLongLongType, &pid64);
    CFDictionarySetValue(d, CFSTR("pid"), n);
    CFRelease(n);
    CFStringRef name;
    if (CopyProcessName(PSN, &name) == noErr) {
        CFDictionarySetValue(d, kCFBundleNameKey, name);
        CFRelease(name);
    }
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof path) > 0) {
        CFStringRef exe = CFStringCreateWithFileSystemRepresentation(NULL, path);
        CFDictionarySetValue(d, kCFBundleExecutableKey, exe);
        CFRelease(exe);
        /* the bundle, when the executable is an app's: .../X.app/Contents/MacOS/x */
        char *macos = strstr(path, ".app/Contents/MacOS/");
        if (macos) {
            macos[4] = 0;
            CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), true);
            CFStringRef bundlePath = CFStringCreateWithFileSystemRepresentation(NULL, path);
            CFDictionarySetValue(d, CFSTR("BundlePath"), bundlePath);
            CFRelease(bundlePath);
            CFBundleRef b = CFBundleCreate(NULL, url);
            CFRelease(url);
            if (b) {
                CFStringRef ident = CFBundleGetIdentifier(b);
                if (ident)
                    CFDictionarySetValue(d, kCFBundleIdentifierKey, ident);
                CFRelease(b);
            }
        }
    }
    return d;
}

OSErr
SetFrontProcess(const ProcessSerialNumber *pPSN)
{
    return psn_pid(pPSN) < 0 ? procNotFound : noErr;
}

OSStatus
SetFrontProcessWithOptions(const ProcessSerialNumber *inProcess, OptionBits inOptions)
{
    return SetFrontProcess(inProcess);
}

OSErr
WakeUpProcess(const ProcessSerialNumber *PSN)
{
    return psn_pid(PSN) < 0 ? procNotFound : noErr;
}

OSErr
ShowHideProcess(const ProcessSerialNumber *psn, Boolean visible)
{
    return psn_pid(psn) < 0 ? procNotFound : noErr;
}

Boolean
IsProcessVisible(const ProcessSerialNumber *psn)
{
    return psn_pid(psn) >= 0;
}

OSErr
KillProcess(const ProcessSerialNumber *inProcess)
{
    pid_t pid = psn_pid(inProcess);
    if (pid < 0)
        return procNotFound;
    return kill(pid, SIGKILL) == 0 ? noErr : procNotFound;
}

OSStatus
TransformProcessType(const ProcessSerialNumber *psn, ProcessApplicationTransformState transformState)
{
    /* an app's activation policy is AppKit's (NSApplication), which the window server follows */
    return psn_pid(psn) < 0 ? procNotFound : noErr;
}

void
ExitToShell(void)
{
    exit(0);
}
