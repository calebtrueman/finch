/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * OSServices: the calls apps still make. UpdateSystemActivity (Power.h)
 * tells the power manager the user is active; Finch has no idle sleep yet,
 * so there's nothing to delay. Processor speed comes from hw.cpufrequency
 * where the kernel reports it. AirDrop isn't supported.
 */
#include "../CarbonCore/CarbonCore_Finch.h"
#include <sys/sysctl.h>
#include <unistd.h>

OSErr
UpdateSystemActivity(UInt8 activity)
{
    return activity <= IdleActivity ? noErr : paramErr;
}

static long
mhz(const char *name)
{
    uint64_t hz = 0;
    size_t n = sizeof hz;
    if (sysctlbyname(name, &hz, &n, NULL, 0))
        return 0;
    return (long)(hz / 1000000);
}

long GetCPUSpeed(void) { return mhz("hw.cpufrequency"); }

FINCH_EXPORT Boolean _CSDeviceSupportsAirDrop(void);
Boolean
_CSDeviceSupportsAirDrop(void)
{
    return false;
}
