/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include <SystemConfiguration/SystemConfiguration.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <stdio.h>
#include <arpa/inet.h>
int main(void)
{
	SCPreferencesRef p = SCPreferencesCreate(
	    NULL, CFSTR("Finch test"), CFSTR("/tmp/finch-nonexistent-preferences-test.plist"));
	assert(p);
	CFDictionaryRef empty = CFDictionaryCreate(
	    NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	assert(SCPreferencesSetValue(p, CFSTR("Nested"), empty));
	assert(SCPreferencesPathGetValue(p, CFSTR("/Nested")));
	assert(!SCPreferencesCommitChanges(p) && SCError() == kSCStatusNoStoreServer);
	CFArrayRef keys = SCPreferencesCopyKeyList(p);
	assert(keys &&
	    CFArrayContainsValue(keys, CFRangeMake(0, CFArrayGetCount(keys)), CFSTR("Nested")));
	CFRelease(keys);
	CFRelease(empty);
	CFRelease(p);
	SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("Finch test"), NULL, NULL);
	assert(store);
	CFStringRef host = SCDynamicStoreCopyComputerName(store, NULL);
	assert(host && CFStringGetLength(host));
	CFRelease(host);
	CFDictionaryRef interfaces =
	    SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Interface"));
	assert(interfaces);
	CFRelease(interfaces);
	keys = SCDynamicStoreCopyKeyList(store, CFSTR("State:/Network/Interface/.*/IPv[46]"));
	assert(keys && CFArrayGetCount(keys) > 0);
	CFDictionaryRef values = SCDynamicStoreCopyMultiple(store, keys, NULL);
	assert(values && CFDictionaryGetCount(values) == CFArrayGetCount(keys));
	CFRelease(values);
	CFRelease(keys);
	assert(!SCDynamicStoreSetValue(store, CFSTR("test"), CFSTR("value")) &&
	    SCError() == kSCStatusNoStoreServer);
	CFRelease(store);
	struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET};
	inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
	SCNetworkReachabilityRef r =
	    SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&address);
	assert(r);
	SCNetworkReachabilityFlags flags = 0;
	assert(SCNetworkReachabilityGetFlags(r, &flags));
	assert(flags & kSCNetworkReachabilityFlagsReachable);
	CFRelease(r);
	CFArrayRef all = SCNetworkInterfaceCopyAll();
	assert(all);
	for (CFIndex i = 0; i < CFArrayGetCount(all); i++) {
		SCNetworkInterfaceRef interface = CFArrayGetValueAtIndex(all, i);
		assert(SCNetworkInterfaceGetBSDName(interface));
		assert(SCNetworkInterfaceGetInterfaceType(interface));
	}
	CFRelease(all);
	puts(
	    "sysconfig-core: PASS (preferences, live interfaces, address reads, route, unavailable writes)");
	return 0;
}
