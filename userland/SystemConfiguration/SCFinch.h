/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Finch's SystemConfiguration: shared internals (docs/design/SECURITY.md). */
#ifndef FINCH_SC_H
#define FINCH_SC_H

#include <SystemConfiguration/SystemConfiguration.h>
#include <CoreFoundation/CFRuntime.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>

#define SC_HIDDEN __attribute__((visibility("hidden")))

#define SC_DEFINE_TYPE(func, name, finalize, equal, hash, describe)                                \
	CFTypeID func(void)                                                                        \
	{                                                                                          \
		static CFTypeID id;                                                                \
		static dispatch_once_t once;                                                       \
		static const CFRuntimeClass cls = {0, name, NULL, NULL, finalize, equal, hash, NULL, describe}; \
		dispatch_once(&once, ^{ id = _CFRuntimeRegisterClass(&cls); });                   \
		return id;                                                                         \
	}

/* SPI constants (configd's SCNetworkConfigurationPrivate.h) */
extern const CFStringRef kSCNetworkInterfaceTypeBridge;

SC_HIDDEN void _SCErrorSet(int error);
SC_HIDDEN CFTypeRef _SCCreateInstance(CFTypeID type, size_t size);   /* size includes CFRuntimeBase */

/* The local state the dynamic store answers from (SCDynamicStore.c). */
SC_HIDDEN CFDictionaryRef _SCCopyLocalState(void);
SC_HIDDEN CFStringRef _SCCopyComputerName(CFStringEncoding *encoding);
SC_HIDDEN CFStringRef _SCCopyLocalHostName(void);

/* System preferences (SCPreferences.c). */
SC_HIDDEN CFDictionaryRef _SCCopySystemPreferences(void);

/* Network change monitor (SCNetworkReachability.c): calls back on a private
 * queue whenever the kernel's routes or addresses change. */
SC_HIDDEN void _SCWatchNetworkChanges(void (^handler)(void));

/* Interfaces (SCNetworkConfiguration.c) */
SC_HIDDEN SCNetworkInterfaceRef _SCNetworkInterfaceCreateFromConfiguration(CFDictionaryRef interface);

#endif
