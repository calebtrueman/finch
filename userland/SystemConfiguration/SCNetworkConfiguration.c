/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Network configuration: interfaces (the kernel's), and the sets, services
 * and protocols of a preferences session (docs/design/SECURITY.md). Reading
 * is complete; editing (creating services, changing protocols) changes the
 * session's preferences, committed with SCPreferencesCommitChanges.
 */
#include "SCFinch.h"
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_types.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Interfaces ---- */

typedef struct {
	CFRuntimeBase base;
	CFStringRef bsdName, type, displayName, hardwareAddress;
	CFDictionaryRef configuration;
} Interface;

static void interfaceFree(CFTypeRef o)
{
	Interface *i = (Interface *)o;
	CFTypeRef refs[] = {i->bsdName, i->type, i->displayName, i->hardwareAddress, i->configuration};
	for (size_t k = 0; k < sizeof(refs) / sizeof(*refs); k++)
		if (refs[k])
			CFRelease(refs[k]);
}
static Boolean interfaceEqual(CFTypeRef a, CFTypeRef b)
{
	Interface *x = (Interface *)a, *y = (Interface *)b;
	return CFEqual(x->type, y->type) && (x->bsdName == y->bsdName || (x->bsdName && y->bsdName && CFEqual(x->bsdName, y->bsdName)));
}
static CFHashCode interfaceHash(CFTypeRef a)
{
	Interface *i = (Interface *)a;
	return i->bsdName ? CFHash(i->bsdName) : CFHash(i->type);
}
static CFStringRef interfaceDescription(CFTypeRef o)
{
	Interface *i = (Interface *)o;
	return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SCNetworkInterface %p> { type = %@, entity_device = %@, name = %@ }"),
	    o, i->type, i->bsdName, i->displayName);
}
SC_DEFINE_TYPE(SCNetworkInterfaceGetTypeID, "SCNetworkInterface", interfaceFree, interfaceEqual, interfaceHash, interfaceDescription)

static Interface *interfaceCreate(CFStringRef bsdName, CFStringRef type, CFStringRef displayName)
{
	Interface *i = (Interface *)_SCCreateInstance(SCNetworkInterfaceGetTypeID(), sizeof(*i));
	i->bsdName = bsdName ? CFRetain(bsdName) : NULL;
	i->type = CFRetain(type);
	i->displayName = displayName ? CFRetain(displayName) : NULL;
	return i;
}

/* kSCNetworkInterfaceIPv4 (SCInterfaceIPv4.c): the virtual interface
 * IPv4-only services sit on. */
const void *_SCCreateIPv4Interface(void);
const void *_SCCreateIPv4Interface(void)
{
	return interfaceCreate(NULL, kSCNetworkInterfaceTypeIPv4, NULL);
}

/* The kernel's interfaces as SCNetworkInterfaceCopyAll reports them: real
 * network hardware, not loopback, tunnels or the kernel's private ones. */
static bool listed(const char *name, CFStringRef *type, CFStringRef *display)
{
	if (!strncmp(name, "en", 2)) {
		*type = kSCNetworkInterfaceTypeEthernet;
		*display = CFSTR("Ethernet");
		return true;
	}
	if (!strncmp(name, "bridge", 6)) {
		*type = kSCNetworkInterfaceTypeBridge;
		*display = CFSTR("Bridge");
		return true;
	}
	if (!strncmp(name, "bond", 4)) {
		*type = kSCNetworkInterfaceTypeBond;
		*display = CFSTR("Bond");
		return true;
	}
	if (!strncmp(name, "vlan", 4)) {
		*type = kSCNetworkInterfaceTypeVLAN;
		*display = CFSTR("VLAN");
		return true;
	}
	return false;
}

CFArrayRef SCNetworkInterfaceCopyAll(void)
{
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	struct ifaddrs *ifa = NULL;
	if (getifaddrs(&ifa) < 0)
		return out;
	for (struct ifaddrs *i = ifa; i; i = i->ifa_next) {
		if (!i->ifa_addr || i->ifa_addr->sa_family != AF_LINK || (i->ifa_flags & IFF_LOOPBACK))
			continue;
		CFStringRef type, display;
		if (!listed(i->ifa_name, &type, &display))
			continue;
		CFStringRef name = CFStringCreateWithCString(NULL, i->ifa_name, kCFStringEncodingUTF8);
		Interface *x = interfaceCreate(name, type, display);
		CFRelease(name);
		struct sockaddr_dl *sdl = (struct sockaddr_dl *)i->ifa_addr;
		if (sdl->sdl_alen == 6) {
			const unsigned char *m = (const unsigned char *)LLADDR(sdl);
			x->hardwareAddress = CFStringCreateWithFormat(NULL, NULL, CFSTR("%02x:%02x:%02x:%02x:%02x:%02x"), m[0], m[1], m[2], m[3], m[4], m[5]);
		}
		CFArrayAppendValue(out, x);
		CFRelease(x);
	}
	freeifaddrs(ifa);
	return out;
}

SCNetworkInterfaceRef _SCNetworkInterfaceCreateFromConfiguration(CFDictionaryRef config)
{
	CFStringRef device = CFDictionaryGetValue(config, kSCPropNetInterfaceDeviceName);
	CFStringRef hardware = CFDictionaryGetValue(config, kSCPropNetInterfaceHardware);
	CFStringRef type = CFDictionaryGetValue(config, kSCPropNetInterfaceType);
	CFStringRef name = CFDictionaryGetValue(config, kSCPropUserDefinedName);
	CFStringRef scType = kSCNetworkInterfaceTypeEthernet;
	if (hardware && CFEqual(hardware, kSCEntNetAirPort))
		scType = kSCNetworkInterfaceTypeIEEE80211;
	else if (type && CFEqual(type, kSCValNetInterfaceTypePPP))
		scType = kSCNetworkInterfaceTypePPP;
	else if (hardware && CFGetTypeID(hardware) == CFStringGetTypeID())
		scType = hardware;
	else if (type && CFGetTypeID(type) == CFStringGetTypeID())
		scType = type;
	Interface *i = interfaceCreate(device, scType, name);
	i->configuration = CFRetain(config);
	return (SCNetworkInterfaceRef)i;
}

static Interface *validInterface(SCNetworkInterfaceRef i)
{
	if (i && CFGetTypeID(i) == SCNetworkInterfaceGetTypeID())
		return (Interface *)i;
	_SCErrorSet(kSCStatusInvalidArgument);
	return NULL;
}

CFStringRef SCNetworkInterfaceGetBSDName(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	return i ? i->bsdName : NULL;
}

CFStringRef SCNetworkInterfaceGetInterfaceType(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	return i ? i->type : NULL;
}

CFStringRef SCNetworkInterfaceGetLocalizedDisplayName(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	return i ? i->displayName : NULL;
}

CFStringRef SCNetworkInterfaceGetHardwareAddressString(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	return i ? i->hardwareAddress : NULL;
}

/* Finch's interfaces don't layer (no PPP over Ethernet yet). */
SCNetworkInterfaceRef SCNetworkInterfaceGetInterface(SCNetworkInterfaceRef interface)
{
	validInterface(interface);
	return NULL;
}

CFDictionaryRef SCNetworkInterfaceGetConfiguration(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	return i ? i->configuration : NULL;
}

CFArrayRef SCNetworkInterfaceGetSupportedInterfaceTypes(SCNetworkInterfaceRef interface)
{
	return NULL;
}

CFArrayRef SCNetworkInterfaceGetSupportedProtocolTypes(SCNetworkInterfaceRef interface)
{
	Interface *i = validInterface(interface);
	if (!i)
		return NULL;
	static CFArrayRef types;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		const void *t[] = {kSCNetworkProtocolTypeDNS, kSCNetworkProtocolTypeIPv4, kSCNetworkProtocolTypeIPv6,
		    kSCNetworkProtocolTypeProxies, kSCNetworkProtocolTypeSMB};
		types = CFArrayCreate(NULL, t, 5, &kCFTypeArrayCallBacks);
	});
	return types;
}

/* ---- Sets, services and protocols over a preferences session ---- */

typedef struct {
	CFRuntimeBase base;
	SCPreferencesRef prefs;
	CFStringRef id;
	CFStringRef protocolType;   /* protocols: the entity; services: NULL */
	CFStringRef serviceID;      /* protocols: their service */
} NetObject;

static void netFree(CFTypeRef o)
{
	NetObject *n = (NetObject *)o;
	CFTypeRef refs[] = {n->prefs, n->id, n->protocolType, n->serviceID};
	for (size_t k = 0; k < sizeof(refs) / sizeof(*refs); k++)
		if (refs[k])
			CFRelease(refs[k]);
}
static Boolean netEqual(CFTypeRef a, CFTypeRef b)
{
	NetObject *x = (NetObject *)a, *y = (NetObject *)b;
	return CFEqual(x->id, y->id) && x->prefs == y->prefs;
}
static CFHashCode netHash(CFTypeRef a)
{
	return CFHash(((NetObject *)a)->id);
}
SC_DEFINE_TYPE(SCNetworkSetGetTypeID, "SCNetworkSet", netFree, netEqual, netHash, NULL)
SC_DEFINE_TYPE(SCNetworkServiceGetTypeID, "SCNetworkService", netFree, netEqual, netHash, NULL)
SC_DEFINE_TYPE(SCNetworkProtocolGetTypeID, "SCNetworkProtocol", netFree, netEqual, netHash, NULL)

static NetObject *netCreate(CFTypeID type, SCPreferencesRef prefs, CFStringRef id)
{
	NetObject *n = (NetObject *)_SCCreateInstance(type, sizeof(*n));
	n->prefs = (SCPreferencesRef)CFRetain(prefs);
	n->id = CFRetain(id);
	return n;
}

static NetObject *validNet(CFTypeRef o, CFTypeID type)
{
	if (o && CFGetTypeID(o) == type)
		return (NetObject *)o;
	_SCErrorSet(kSCStatusInvalidArgument);
	return NULL;
}

static CFDictionaryRef pathValue(SCPreferencesRef prefs, CFStringRef fmt, ...) CF_FORMAT_FUNCTION(2, 3);
static CFDictionaryRef pathValue(SCPreferencesRef prefs, CFStringRef fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	CFStringRef path = CFStringCreateWithFormatAndArguments(NULL, NULL, fmt, ap);
	va_end(ap);
	CFDictionaryRef d = SCPreferencesPathGetValue(prefs, path);
	CFRelease(path);
	return d;
}

static CFComparisonResult compareStrings(const void *a, const void *b, void *context)
{
	return CFStringCompare(a, b, 0);
}

static CFArrayRef sortedKeys(CFDictionaryRef d)
{
	CFIndex n = d ? CFDictionaryGetCount(d) : 0;
	const void **keys = malloc(sizeof(void *) * (n ? n : 1));
	if (d)
		CFDictionaryGetKeysAndValues(d, keys, NULL);
	CFMutableArrayRef a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < n; i++)
		if (CFGetTypeID(keys[i]) == CFStringGetTypeID())
			CFArrayAppendValue(a, keys[i]);
	free(keys);
	CFArraySortValues(a, CFRangeMake(0, CFArrayGetCount(a)), compareStrings, NULL);
	return a;
}

SCNetworkSetRef SCNetworkSetCopyCurrent(SCPreferencesRef prefs)
{
	CFStringRef current = SCPreferencesGetValue(prefs, kSCPrefCurrentSet);
	if (!current || CFGetTypeID(current) != CFStringGetTypeID() || !CFStringHasPrefix(current, CFSTR("/Sets/"))) {
		_SCErrorSet(kSCStatusNoKey);
		return NULL;
	}
	CFStringRef id = CFStringCreateWithSubstring(NULL, current, CFRangeMake(6, CFStringGetLength(current) - 6));
	NetObject *set = pathValue(prefs, CFSTR("/Sets/%@"), id) ? netCreate(SCNetworkSetGetTypeID(), prefs, id) : NULL;
	CFRelease(id);
	_SCErrorSet(set ? kSCStatusOK : kSCStatusNoKey);
	return (SCNetworkSetRef)set;
}

SCNetworkSetRef SCNetworkSetCopy(SCPreferencesRef prefs, CFStringRef setID)
{
	if (!setID || !pathValue(prefs, CFSTR("/Sets/%@"), setID)) {
		_SCErrorSet(kSCStatusNoKey);
		return NULL;
	}
	return (SCNetworkSetRef)netCreate(SCNetworkSetGetTypeID(), prefs, setID);
}

CFArrayRef SCNetworkSetCopyAll(SCPreferencesRef prefs)
{
	CFDictionaryRef sets = SCPreferencesGetValue(prefs, kSCPrefSets);
	CFArrayRef ids = sortedKeys(sets && CFGetTypeID(sets) == CFDictionaryGetTypeID() ? sets : NULL);
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(ids); i++) {
		NetObject *s = netCreate(SCNetworkSetGetTypeID(), prefs, CFArrayGetValueAtIndex(ids, i));
		CFArrayAppendValue(out, s);
		CFRelease(s);
	}
	CFRelease(ids);
	_SCErrorSet(kSCStatusOK);
	return out;
}

CFStringRef SCNetworkSetGetSetID(SCNetworkSetRef set)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	return n ? n->id : NULL;
}

CFStringRef SCNetworkSetGetName(SCNetworkSetRef set)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	CFDictionaryRef d = n ? pathValue(n->prefs, CFSTR("/Sets/%@"), n->id) : NULL;
	return d ? CFDictionaryGetValue(d, kSCPropUserDefinedName) : NULL;
}

CFArrayRef SCNetworkSetGetServiceOrder(SCNetworkSetRef set)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	CFDictionaryRef d = n ? pathValue(n->prefs, CFSTR("/Sets/%@/Network/Global/IPv4"), n->id) : NULL;
	CFArrayRef order = d ? CFDictionaryGetValue(d, kSCPropNetServiceOrder) : NULL;
	return order && CFGetTypeID(order) == CFArrayGetTypeID() ? order : NULL;
}

CFArrayRef SCNetworkSetCopyServices(SCNetworkSetRef set)
{
	NetObject *n = validNet(set, SCNetworkSetGetTypeID());
	if (!n)
		return NULL;
	CFStringRef base = CFStringCreateWithFormat(NULL, NULL, CFSTR("/Sets/%@/Network/Service"), n->id);
	CFDictionaryRef services = SCPreferencesPathGetValue(n->prefs, base);
	CFArrayRef ids = sortedKeys(services);
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(ids); i++) {
		CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@/%@"), base, CFArrayGetValueAtIndex(ids, i));
		CFStringRef link = SCPreferencesPathGetLink(n->prefs, path);
		CFRelease(path);
		CFStringRef sid = link && CFStringHasPrefix(link, CFSTR("/NetworkServices/"))
		    ? CFStringCreateWithSubstring(NULL, link, CFRangeMake(17, CFStringGetLength(link) - 17))
		    : CFRetain(CFArrayGetValueAtIndex(ids, i));
		NetObject *s = netCreate(SCNetworkServiceGetTypeID(), n->prefs, sid);
		CFArrayAppendValue(out, s);
		CFRelease(s);
		CFRelease(sid);
	}
	CFRelease(ids);
	CFRelease(base);
	_SCErrorSet(kSCStatusOK);
	return out;
}

CFArrayRef SCNetworkServiceCopyAll(SCPreferencesRef prefs)
{
	CFDictionaryRef services = SCPreferencesGetValue(prefs, kSCPrefNetworkServices);
	CFArrayRef ids = sortedKeys(services && CFGetTypeID(services) == CFDictionaryGetTypeID() ? services : NULL);
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(ids); i++) {
		NetObject *s = netCreate(SCNetworkServiceGetTypeID(), prefs, CFArrayGetValueAtIndex(ids, i));
		CFArrayAppendValue(out, s);
		CFRelease(s);
	}
	CFRelease(ids);
	_SCErrorSet(kSCStatusOK);
	return out;
}

SCNetworkServiceRef SCNetworkServiceCopy(SCPreferencesRef prefs, CFStringRef serviceID)
{
	if (!serviceID || !pathValue(prefs, CFSTR("/NetworkServices/%@"), serviceID)) {
		_SCErrorSet(kSCStatusNoKey);
		return NULL;
	}
	return (SCNetworkServiceRef)netCreate(SCNetworkServiceGetTypeID(), prefs, serviceID);
}

static CFDictionaryRef serviceDict(NetObject *n)
{
	return n ? pathValue(n->prefs, CFSTR("/NetworkServices/%@"), n->id) : NULL;
}

CFStringRef SCNetworkServiceGetServiceID(SCNetworkServiceRef service)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	return n ? n->id : NULL;
}

CFStringRef SCNetworkServiceGetName(SCNetworkServiceRef service)
{
	CFDictionaryRef d = serviceDict(validNet(service, SCNetworkServiceGetTypeID()));
	return d ? CFDictionaryGetValue(d, kSCPropUserDefinedName) : NULL;
}

Boolean SCNetworkServiceGetEnabled(SCNetworkServiceRef service)
{
	CFDictionaryRef d = serviceDict(validNet(service, SCNetworkServiceGetTypeID()));
	return d && !CFDictionaryContainsKey(d, kSCResvInactive);
}

SCNetworkInterfaceRef SCNetworkServiceGetInterface(SCNetworkServiceRef service)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	CFDictionaryRef d = serviceDict(n);
	CFDictionaryRef config = d ? CFDictionaryGetValue(d, kSCEntNetInterface) : NULL;
	if (!config || CFGetTypeID(config) != CFDictionaryGetTypeID())
		return NULL;
	/* Kept for the service's lifetime, as Apple's returns it unretained. */
	static CFMutableDictionaryRef cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cache = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	});
	SCNetworkInterfaceRef i = _SCNetworkInterfaceCreateFromConfiguration(config);
	SCNetworkInterfaceRef have = (SCNetworkInterfaceRef)CFDictionaryGetValue(cache, i);
	if (have) {
		CFRelease(i);
		return have;
	}
	CFDictionarySetValue(cache, i, i);
	CFRelease(i);
	return i;
}

static bool isProtocolEntity(CFStringRef k)
{
	return CFEqual(k, kSCNetworkProtocolTypeDNS) || CFEqual(k, kSCNetworkProtocolTypeIPv4) ||
	    CFEqual(k, kSCNetworkProtocolTypeIPv6) || CFEqual(k, kSCNetworkProtocolTypeProxies) ||
	    CFEqual(k, kSCNetworkProtocolTypeSMB);
}

static SCNetworkProtocolRef protocolCreate(NetObject *service, CFStringRef type)
{
	CFStringRef id = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@/%@"), service->id, type);
	NetObject *p = netCreate(SCNetworkProtocolGetTypeID(), service->prefs, id);
	CFRelease(id);
	p->protocolType = CFRetain(type);
	p->serviceID = CFRetain(service->id);
	return (SCNetworkProtocolRef)p;
}

CFArrayRef SCNetworkServiceCopyProtocols(SCNetworkServiceRef service)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	CFDictionaryRef d = serviceDict(n);
	if (!d)
		return NULL;
	CFArrayRef keys = sortedKeys(d);
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < CFArrayGetCount(keys); i++)
		if (isProtocolEntity(CFArrayGetValueAtIndex(keys, i))) {
			SCNetworkProtocolRef p = protocolCreate(n, CFArrayGetValueAtIndex(keys, i));
			CFArrayAppendValue(out, p);
			CFRelease(p);
		}
	CFRelease(keys);
	return out;
}

SCNetworkProtocolRef SCNetworkServiceCopyProtocol(SCNetworkServiceRef service, CFStringRef protocolType)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	CFDictionaryRef d = serviceDict(n);
	if (!d || !protocolType || !CFDictionaryGetValue(d, protocolType)) {
		_SCErrorSet(kSCStatusNoKey);
		return NULL;
	}
	return protocolCreate(n, protocolType);
}

static CFDictionaryRef protocolDict(NetObject *p)
{
	return p ? pathValue(p->prefs, CFSTR("/NetworkServices/%@/%@"), p->serviceID, p->protocolType) : NULL;
}

CFStringRef SCNetworkProtocolGetProtocolType(SCNetworkProtocolRef protocol)
{
	NetObject *p = validNet(protocol, SCNetworkProtocolGetTypeID());
	return p ? p->protocolType : NULL;
}

CFDictionaryRef SCNetworkProtocolGetConfiguration(SCNetworkProtocolRef protocol)
{
	CFDictionaryRef d = protocolDict(validNet(protocol, SCNetworkProtocolGetTypeID()));
	if (!d || !CFDictionaryContainsKey(d, kSCResvInactive))
		return d;
	/* The configuration without the inactive marker. */
	static CFMutableDictionaryRef cache;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		cache = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	});
	CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(NULL, 0, d);
	CFDictionaryRemoveValue(copy, kSCResvInactive);
	CFDictionarySetValue(cache, protocol, copy);
	CFRelease(copy);
	return copy;
}

Boolean SCNetworkProtocolGetEnabled(SCNetworkProtocolRef protocol)
{
	CFDictionaryRef d = protocolDict(validNet(protocol, SCNetworkProtocolGetTypeID()));
	return d && !CFDictionaryContainsKey(d, kSCResvInactive);
}

Boolean SCNetworkProtocolSetConfiguration(SCNetworkProtocolRef protocol, CFDictionaryRef config)
{
	NetObject *p = validNet(protocol, SCNetworkProtocolGetTypeID());
	if (!p)
		return false;
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@/%@"), p->serviceID, p->protocolType);
	Boolean ok = config ? SCPreferencesPathSetValue(p->prefs, path, config) : SCPreferencesPathRemoveValue(p->prefs, path);
	CFRelease(path);
	return ok;
}

static Boolean setInactive(SCPreferencesRef prefs, CFStringRef path, Boolean enabled)
{
	CFDictionaryRef d = SCPreferencesPathGetValue(prefs, path);
	if (!d)
		return false;
	CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
	if (enabled)
		CFDictionaryRemoveValue(m, kSCResvInactive);
	else
		CFDictionarySetValue(m, kSCResvInactive, kCFBooleanTrue);
	Boolean ok = SCPreferencesPathSetValue(prefs, path, m);
	CFRelease(m);
	return ok;
}

Boolean SCNetworkProtocolSetEnabled(SCNetworkProtocolRef protocol, Boolean enabled)
{
	NetObject *p = validNet(protocol, SCNetworkProtocolGetTypeID());
	if (!p)
		return false;
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@/%@"), p->serviceID, p->protocolType);
	Boolean ok = setInactive(p->prefs, path, enabled);
	CFRelease(path);
	return ok;
}

Boolean SCNetworkServiceSetEnabled(SCNetworkServiceRef service, Boolean enabled)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	if (!n)
		return false;
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@"), n->id);
	Boolean ok = setInactive(n->prefs, path, enabled);
	CFRelease(path);
	return ok;
}

Boolean SCNetworkServiceSetName(SCNetworkServiceRef service, CFStringRef name)
{
	NetObject *n = validNet(service, SCNetworkServiceGetTypeID());
	CFDictionaryRef d = serviceDict(n);
	if (!d)
		return false;
	CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
	if (name)
		CFDictionarySetValue(m, kSCPropUserDefinedName, name);
	else
		CFDictionaryRemoveValue(m, kSCPropUserDefinedName);
	CFStringRef path = CFStringCreateWithFormat(NULL, NULL, CFSTR("/NetworkServices/%@"), n->id);
	Boolean ok = SCPreferencesPathSetValue(n->prefs, path, m);
	CFRelease(path);
	CFRelease(m);
	return ok;
}
