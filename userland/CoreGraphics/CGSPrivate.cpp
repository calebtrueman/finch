/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Private window-server calls apps make directly (Apple's CGS* and CPS*, which its
 * CoreGraphics re-exports from SkyLight), answered from Finch's window-server client.
 * Signatures are Apple's, read from its binaries.
 */
#include "CGInternal.h"
#include <stdatomic.h>
#include <unistd.h>

typedef int CGSConnectionID;
typedef uint32_t CGSWindowID;

/* Carbon's process serial number, as the CPS calls take it. */
typedef struct {
    uint32_t hi, lo;
} CPSProcessSerNum;

extern "C" {
CGSConnectionID CGSMainConnectionID(void);
CGError CGSSetSecureEventInput(CGSConnectionID cid, bool enabled);
CGError CGSSetWindowBackgroundBlurRadiusWithOpacityHint(CGSConnectionID cid, CGSWindowID wid, int radius,
                                                        CGFloat opacityHint);
int32_t CPSGetCurrentProcess(CPSProcessSerNum *psn);
int32_t CPSStealKeyFocus(CPSProcessSerNum *psn);
int32_t CPSReleaseKeyFocus(CPSProcessSerNum *psn);
bool FWSSecureEventInputEnabled(void);
}

/* One connection per process: its ID is the process's. */
CGSConnectionID
CGSMainConnectionID(void)
{
    return (CGSConnectionID)getpid();
}

static atomic_int secure_input;

/* Secure keyboard entry (Terminal's, password fields'): counted, as Apple's is. The
   window server doesn't let other processes watch keys yet, so there is nothing more
   to switch. */
CGError
CGSSetSecureEventInput(CGSConnectionID cid, bool enabled)
{
    if (enabled)
        atomic_fetch_add(&secure_input, 1);
    else if (atomic_load(&secure_input) > 0)
        atomic_fetch_sub(&secure_input, 1);
    return kCGErrorSuccess;
}

bool
FWSSecureEventInputEnabled(void)
{
    return atomic_load(&secure_input) > 0;
}

/* A window's background blur: Finch's window server composites without blur yet. */
CGError
CGSSetWindowBackgroundBlurRadiusWithOpacityHint(CGSConnectionID cid, CGSWindowID wid, int radius, CGFloat opacityHint)
{
    return kCGErrorSuccess;
}

int32_t
CPSGetCurrentProcess(CPSProcessSerNum *psn)
{
    if (!psn)
        return -50; /* paramErr */
    psn->hi = 1;
    psn->lo = (uint32_t)getpid(); /* as HIServices' Process Manager numbers processes */
    return 0;
}

/* Key focus is AppKit's and the window server's: stealing or releasing it is accepted. */
int32_t
CPSStealKeyFocus(CPSProcessSerNum *psn)
{
    return 0;
}

int32_t
CPSReleaseKeyFocus(CPSProcessSerNum *psn)
{
    return 0;
}
