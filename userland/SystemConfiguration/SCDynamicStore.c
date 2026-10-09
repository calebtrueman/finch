/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * SCDynamicStore without configd (docs/design/SECURITY.md).
 *
 * The store answers from the system's own state, read when asked:
 *   Setup:/System                       computer name (preferences, else the host name)
 *   Setup:/Network/HostNames            local host name (preferences, else derived)
 *   State:/Users/ConsoleUser            the owner of /dev/console (unless root)
 *   State:/Network/Interface            the kernel's interfaces (getifaddrs)
 *   State:/Network/Interface/<if>/IPv4  addresses, masks, broadcast addresses
 *   State:/Network/Interface/<if>/IPv6  addresses, prefix lengths, flags
 *   State:/Network/Interface/<if>/Link  whether the link is up
 *   State:/Network/Global/IPv4, IPv6    primary interface and router (default route)
 *   State:/Network/Global/DNS           /etc/resolv.conf
 *   State:/Network/Global/Proxies       the primary service's proxies, else Apple's defaults
 * Values a process sets are kept in that process (configd would share them).
 * Notifications: keys under State:/Network/ are watched through the kernel's
 * routing socket, and a process's own writes notify it; nothing else changes.
 */
#include "SCFinch.h"
#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <netinet/in.h>
#include <netinet6/in6_var.h>
#include <pthread.h>
#include <pwd.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/sysctl.h>
#include <unistd.h>

static void setString(CFMutableDictionaryRef d, CFStringRef k, const char *s)
{
	CFStringRef v = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
	if (v) {
		CFDictionarySetValue(d, k, v);
		CFRelease(v);
	}
}

static void setInt(CFMutableDictionaryRef d, CFStringRef k, int n)
{
	CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &n);
	CFDictionarySetValue(d, k, v);
	CFRelease(v);
}

static CFMutableDictionaryRef newDict(void)
{
	return CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
}

static CFMutableArrayRef arrayIn(CFMutableDictionaryRef d, CFStringRef k)
{
	CFMutableArrayRef a = (CFMutableArrayRef)CFDictionaryGetValue(d, k);
	if (!a) {
		a = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		CFDictionarySetValue(d, k, a);
		CFRelease(a);
	}
	return a;
}

static void appendString(CFMutableArrayRef a, const char *s)
{
	CFStringRef v = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
	CFArrayAppendValue(a, v);
	CFRelease(v);
}

static void appendInt(CFMutableArrayRef a, int n)
{
	CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &n);
	CFArrayAppendValue(a, v);
	CFRelease(v);
}

/* ---- Names ---- */

static CFDictionaryRef prefsPath(CFDictionaryRef prefs, const char *const *path)
{
	CFTypeRef d = prefs;
	for (int i = 0; d && path[i]; i++) {
		if (CFGetTypeID(d) != CFDictionaryGetTypeID())
			return NULL;
		CFStringRef k = CFStringCreateWithCString(NULL, path[i], kCFStringEncodingUTF8);
		d = CFDictionaryGetValue(d, k);
		CFRelease(k);
	}
	return d && CFGetTypeID(d) == CFDictionaryGetTypeID() ? d : NULL;
}

CFStringRef _SCCopyComputerName(CFStringEncoding *encoding)
{
	CFDictionaryRef prefs = _SCCopySystemPreferences();
	static const char *const path[] = {"System", "System", NULL};
	CFDictionaryRef sys = prefs ? prefsPath(prefs, path) : NULL;
	CFStringRef name = sys ? CFDictionaryGetValue(sys, kSCPropSystemComputerName) : NULL;
	CFStringEncoding enc = kCFStringEncodingMacRoman;
	if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
		CFNumberRef n = CFDictionaryGetValue(sys, kSCPropSystemComputerNameEncoding);
		if (n && CFGetTypeID(n) == CFNumberGetTypeID())
			CFNumberGetValue(n, kCFNumberSInt32Type, &enc);
		CFRetain(name);
	} else {
		char host[256] = "";
		gethostname(host, sizeof(host));
		char *dot = strchr(host, '.');
		if (dot)
			*dot = 0;
		name = CFStringCreateWithCString(NULL, host[0] ? host : "localhost", kCFStringEncodingUTF8);
	}
	if (prefs)
		CFRelease(prefs);
	if (encoding)
		*encoding = enc;
	return name;
}

/* A computer name as a host name label: letters, digits and hyphens. */
static CFStringRef hostLabel(CFStringRef name)
{
	CFMutableStringRef s = CFStringCreateMutable(NULL, 0);
	bool hyphen = false;
	for (CFIndex i = 0; i < CFStringGetLength(name) && CFStringGetLength(s) < 63; i++) {
		UniChar c = CFStringGetCharacterAtIndex(name, i);
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			CFStringAppendCharacters(s, &c, 1);
			hyphen = false;
		} else if ((c == ' ' || c == '-' || c == '_' || c == '.') && !hyphen && CFStringGetLength(s)) {
			CFStringAppendCString(s, "-", kCFStringEncodingASCII);
			hyphen = true;
		}
	}
	if (hyphen)
		CFStringDelete(s, CFRangeMake(CFStringGetLength(s) - 1, 1));
	if (!CFStringGetLength(s))
		CFStringAppendCString(s, "localhost", kCFStringEncodingASCII);
	return s;
}

CFStringRef _SCCopyLocalHostName(void)
{
	CFDictionaryRef prefs = _SCCopySystemPreferences();
	static const char *const path[] = {"System", "Network", "HostNames", NULL};
	CFDictionaryRef hn = prefs ? prefsPath(prefs, path) : NULL;
	CFStringRef name = hn ? CFDictionaryGetValue(hn, kSCPropNetLocalHostName) : NULL;
	if (name && CFGetTypeID(name) == CFStringGetTypeID())
		CFRetain(name);
	else {
		CFStringRef computer = _SCCopyComputerName(NULL);
		name = hostLabel(computer);
		CFRelease(computer);
	}
	if (prefs)
		CFRelease(prefs);
	return name;
}

/* ---- The network state ---- */

static CFMutableDictionaryRef entity(CFMutableDictionaryRef state, const char *ifname, CFStringRef ent)
{
	CFStringRef key = CFStringCreateWithFormat(NULL, NULL, CFSTR("State:/Network/Interface/%s/%@"), ifname, ent);
	CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFDictionaryGetValue(state, key);
	if (!d) {
		d = newDict();
		CFDictionarySetValue(state, key, d);
		CFRelease(d);
	}
	CFRelease(key);
	return d;
}

static int prefixLength(const struct in6_addr *mask)
{
	int n = 0;
	for (int i = 0; i < 16; i++)
		for (int b = 7; b >= 0; b--) {
			if (!(mask->s6_addr[i] & (1 << b)))
				return n;
			n++;
		}
	return n;
}

static void addInterfaces(CFMutableDictionaryRef state)
{
	struct ifaddrs *ifa = NULL;
	if (getifaddrs(&ifa) < 0)
		return;
	CFMutableDictionaryRef list = newDict();
	CFMutableArrayRef names = arrayIn(list, CFSTR("Interfaces"));
	int s6 = socket(AF_INET6, SOCK_DGRAM, 0);
	for (struct ifaddrs *i = ifa; i; i = i->ifa_next) {
		CFStringRef n = CFStringCreateWithCString(NULL, i->ifa_name, kCFStringEncodingUTF8);
		if (!CFArrayContainsValue(names, CFRangeMake(0, CFArrayGetCount(names)), n))
			CFArrayAppendValue(names, n);
		CFRelease(n);
		if (!i->ifa_addr)
			continue;
		char buf[INET6_ADDRSTRLEN];
		if (i->ifa_addr->sa_family == AF_INET) {
			CFMutableDictionaryRef d = entity(state, i->ifa_name, kSCEntNetIPv4);
			inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, buf, sizeof(buf));
			appendString(arrayIn(d, kSCPropNetIPv4Addresses), buf);
			if (i->ifa_netmask) {
				inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_netmask)->sin_addr, buf, sizeof(buf));
				appendString(arrayIn(d, kSCPropNetIPv4SubnetMasks), buf);
			}
			if ((i->ifa_flags & IFF_BROADCAST) && i->ifa_dstaddr) {
				inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_dstaddr)->sin_addr, buf, sizeof(buf));
				appendString(arrayIn(d, kSCPropNetIPv4BroadcastAddresses), buf);
			}
		} else if (i->ifa_addr->sa_family == AF_INET6) {
			CFMutableDictionaryRef d = entity(state, i->ifa_name, kSCEntNetIPv6);
			struct sockaddr_in6 sin6 = *(struct sockaddr_in6 *)i->ifa_addr;
			if (IN6_IS_ADDR_LINKLOCAL(&sin6.sin6_addr)) {
				/* The kernel embeds the scope in the address. */
				sin6.sin6_addr.s6_addr[2] = sin6.sin6_addr.s6_addr[3] = 0;
			}
			inet_ntop(AF_INET6, &sin6.sin6_addr, buf, sizeof(buf));
			appendString(arrayIn(d, kSCPropNetIPv6Addresses), buf);
			appendInt(arrayIn(d, kSCPropNetIPv6PrefixLength),
			    i->ifa_netmask ? prefixLength(&((struct sockaddr_in6 *)i->ifa_netmask)->sin6_addr) : 128);
			int flags = 0;
			struct in6_ifreq ifr;
			memset(&ifr, 0, sizeof(ifr));
			strlcpy(ifr.ifr_name, i->ifa_name, sizeof(ifr.ifr_name));
			ifr.ifr_addr = *(struct sockaddr_in6 *)i->ifa_addr;
			if (s6 >= 0 && ioctl(s6, SIOCGIFAFLAG_IN6, &ifr) == 0)
				flags = ifr.ifr_ifru.ifru_flags6;
			appendInt(arrayIn(d, kSCPropNetIPv6Flags), flags);
		} else if (i->ifa_addr->sa_family == AF_LINK && !(i->ifa_flags & IFF_LOOPBACK)) {
			CFMutableDictionaryRef d = entity(state, i->ifa_name, kSCEntNetLink);
			CFDictionarySetValue(d, kSCPropNetLinkActive, (i->ifa_flags & IFF_RUNNING) ? kCFBooleanTrue : kCFBooleanFalse);
		}
	}
	if (s6 >= 0)
		close(s6);
	freeifaddrs(ifa);
	CFDictionarySetValue(state, CFSTR("State:/Network/Interface"), list);
	CFRelease(list);
}

/* The default route for a family: its interface and gateway. */
static bool defaultRoute(int family, char *ifname, size_t ifsize, char *router, size_t rsize)
{
	int mib[6] = {CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, RTF_GATEWAY};
	size_t len = 0;
	if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0 || len == 0)
		return false;
	char *buf = malloc(len);
	bool found = false;
	if (sysctl(mib, 6, buf, &len, NULL, 0) == 0) {
		for (char *p = buf; !found && p < buf + len;) {
			struct rt_msghdr *rtm = (struct rt_msghdr *)p;
			if (rtm->rtm_msglen == 0)
				break;
			struct sockaddr *sa = (struct sockaddr *)(rtm + 1);
			struct sockaddr *addrs[RTAX_MAX] = {0};
			for (int i = 0; i < RTAX_MAX; i++) {
				if (!(rtm->rtm_addrs & (1 << i)))
					continue;
				addrs[i] = sa;
				size_t l = sa->sa_len ? ((sa->sa_len + 3) & ~3u) : 4;
				sa = (struct sockaddr *)((char *)sa + l);
			}
			struct sockaddr *dst = addrs[RTAX_DST], *gw = addrs[RTAX_GATEWAY], *mask = addrs[RTAX_NETMASK];
			bool isDefault = dst && dst->sa_family == family &&
			    (family == AF_INET ? ((struct sockaddr_in *)dst)->sin_addr.s_addr == 0
			                       : IN6_IS_ADDR_UNSPECIFIED(&((struct sockaddr_in6 *)dst)->sin6_addr)) &&
			    (!mask || mask->sa_len <= 2 ||
			        (family == AF_INET ? ((struct sockaddr_in *)mask)->sin_addr.s_addr == 0
			                           : IN6_IS_ADDR_UNSPECIFIED(&((struct sockaddr_in6 *)mask)->sin6_addr)));
			if (isDefault && (rtm->rtm_flags & RTF_UP) && !(rtm->rtm_flags & RTF_IFSCOPE)) {
				if (!if_indextoname(rtm->rtm_index, ifname))
					ifname[0] = 0;
				router[0] = 0;
				if (gw && gw->sa_family == AF_INET)
					inet_ntop(AF_INET, &((struct sockaddr_in *)gw)->sin_addr, router, rsize);
				else if (gw && gw->sa_family == AF_INET6) {
					struct sockaddr_in6 g = *(struct sockaddr_in6 *)gw;
					if (IN6_IS_ADDR_LINKLOCAL(&g.sin6_addr))
						g.sin6_addr.s6_addr[2] = g.sin6_addr.s6_addr[3] = 0;
					inet_ntop(AF_INET6, &g.sin6_addr, router, rsize);
				}
				found = ifname[0] != 0;
			}
			p += rtm->rtm_msglen;
		}
	}
	free(buf);
	(void)ifsize;
	return found;
}

static void addGlobal(CFMutableDictionaryRef state)
{
	char ifname[IF_NAMESIZE + 1], router[INET6_ADDRSTRLEN];
	int families[] = {AF_INET, AF_INET6};
	CFStringRef keys[] = {CFSTR("State:/Network/Global/IPv4"), CFSTR("State:/Network/Global/IPv6")};
	for (int i = 0; i < 2; i++)
		if (defaultRoute(families[i], ifname, sizeof(ifname), router, sizeof(router))) {
			CFMutableDictionaryRef d = newDict();
			setString(d, CFSTR("PrimaryInterface"), ifname);
			if (router[0])
				setString(d, kSCPropNetIPv4Router, router);
			CFDictionarySetValue(state, keys[i], d);
			CFRelease(d);
		}
}

static void addDNS(CFMutableDictionaryRef state)
{
	FILE *f = fopen("/etc/resolv.conf", "r");
	if (!f)
		return;
	CFMutableDictionaryRef d = newDict();
	char line[512];
	while (fgets(line, sizeof(line), f)) {
		char *save = NULL, *word = strtok_r(line, " \t\r\n", &save);
		if (!word || word[0] == '#' || word[0] == ';')
			continue;
		if (!strcmp(word, "nameserver")) {
			char *a = strtok_r(NULL, " \t\r\n", &save);
			if (a)
				appendString(arrayIn(d, kSCPropNetDNSServerAddresses), a);
		} else if (!strcmp(word, "search")) {
			for (char *w; (w = strtok_r(NULL, " \t\r\n", &save));)
				appendString(arrayIn(d, kSCPropNetDNSSearchDomains), w);
		} else if (!strcmp(word, "domain")) {
			char *w = strtok_r(NULL, " \t\r\n", &save);
			if (w)
				setString(d, kSCPropNetDNSDomainName, w);
		}
	}
	fclose(f);
	if (CFDictionaryGetCount(d))
		CFDictionarySetValue(state, CFSTR("State:/Network/Global/DNS"), d);
	CFRelease(d);
}

/* The proxies of the first active service in the current set, else the
 * defaults macOS reports when none are configured. */
static void addProxies(CFMutableDictionaryRef state)
{
	CFDictionaryRef proxies = NULL;
	CFDictionaryRef prefs = _SCCopySystemPreferences();
	CFStringRef current = prefs ? CFDictionaryGetValue(prefs, kSCPrefCurrentSet) : NULL;
	if (current && CFGetTypeID(current) == CFStringGetTypeID() && CFStringHasPrefix(current, CFSTR("/Sets/"))) {
		CFStringRef setID = CFStringCreateWithSubstring(NULL, current, CFRangeMake(6, CFStringGetLength(current) - 6));
		CFDictionaryRef sets = CFDictionaryGetValue(prefs, kSCPrefSets);
		CFDictionaryRef set = sets && CFGetTypeID(sets) == CFDictionaryGetTypeID() ? CFDictionaryGetValue(sets, setID) : NULL;
		static const char *const orderPath[] = {"Network", "Global", "IPv4", NULL};
		CFDictionaryRef global = set ? prefsPath(set, orderPath) : NULL;
		CFArrayRef order = global ? CFDictionaryGetValue(global, CFSTR("ServiceOrder")) : NULL;
		CFDictionaryRef services = CFDictionaryGetValue(prefs, kSCPrefNetworkServices);
		for (CFIndex i = 0; !proxies && order && CFGetTypeID(order) == CFArrayGetTypeID() && i < CFArrayGetCount(order); i++) {
			CFDictionaryRef svc = services ? CFDictionaryGetValue(services, CFArrayGetValueAtIndex(order, i)) : NULL;
			if (!svc || CFGetTypeID(svc) != CFDictionaryGetTypeID() || CFDictionaryGetValue(svc, kSCResvInactive))
				continue;
			CFDictionaryRef p = CFDictionaryGetValue(svc, kSCEntNetProxies);
			if (p && CFGetTypeID(p) == CFDictionaryGetTypeID())
				proxies = CFRetain(p);
		}
		CFRelease(setID);
	}
	if (prefs)
		CFRelease(prefs);
	if (!proxies) {
		CFMutableDictionaryRef d = newDict();
		CFMutableArrayRef ex = arrayIn(d, kSCPropNetProxiesExceptionsList);
		appendString(ex, "*.local");
		appendString(ex, "169.254/16");
		setInt(d, kSCPropNetProxiesFTPPassive, 1);
		proxies = d;
	}
	CFDictionarySetValue(state, CFSTR("State:/Network/Global/Proxies"), proxies);
	CFRelease(proxies);
}

static void addSystem(CFMutableDictionaryRef state)
{
	CFDictionaryRef prefs = _SCCopySystemPreferences();
	CFStringRef current = prefs ? CFDictionaryGetValue(prefs, kSCPrefCurrentSet) : NULL;
	if (current && CFGetTypeID(current) == CFStringGetTypeID()) {
		CFMutableDictionaryRef setup = newDict();
		CFDictionarySetValue(setup, kSCDynamicStorePropSetupCurrentSet, current);
		CFDictionarySetValue(state, CFSTR("Setup:"), setup);
		CFRelease(setup);
	}
	if (prefs)
		CFRelease(prefs);

	CFStringEncoding enc;
	CFStringRef name = _SCCopyComputerName(&enc);
	CFMutableDictionaryRef d = newDict();
	CFDictionarySetValue(d, kSCPropSystemComputerName, name);
	setInt(d, kSCPropSystemComputerNameEncoding, (int)enc);
	CFDictionarySetValue(state, CFSTR("Setup:/System"), d);
	CFRelease(d);
	CFRelease(name);
	CFStringRef local = _SCCopyLocalHostName();
	d = newDict();
	CFDictionarySetValue(d, kSCPropNetLocalHostName, local);
	CFDictionarySetValue(state, CFSTR("Setup:/Network/HostNames"), d);
	CFRelease(d);
	CFRelease(local);

	struct stat st;
	if (stat("/dev/console", &st) == 0 && st.st_uid != 0) {
		struct passwd *pw = getpwuid(st.st_uid);
		if (pw) {
			d = newDict();
			setString(d, CFSTR("Name"), pw->pw_name);
			setInt(d, CFSTR("UID"), (int)pw->pw_uid);
			setInt(d, CFSTR("GID"), (int)pw->pw_gid);
			CFDictionarySetValue(state, CFSTR("State:/Users/ConsoleUser"), d);
			CFRelease(d);
		}
	}
}

CFDictionaryRef _SCCopyLocalState(void)
{
	CFMutableDictionaryRef state = newDict();
	addSystem(state);
	addInterfaces(state);
	addGlobal(state);
	addDNS(state);
	addProxies(state);
	return state;
}

/* ---- Sessions ---- */

typedef struct Store {
	CFRuntimeBase base;
	CFStringRef name;
	SCDynamicStoreCallBack callout;
	SCDynamicStoreContext context;
	CFArrayRef watchedKeys, watchedPatterns;
	CFMutableArrayRef changed;
	CFDictionaryRef snapshot;     /* the watched values, to diff against */
	dispatch_queue_t queue;
	CFRunLoopSourceRef source;
	CFMutableArrayRef runLoops;
	bool watching;
	struct Store *nextWatcher;
} Store;

static pthread_mutex_t storeLock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableDictionaryRef localValues;   /* this process's writes */
static Store *watchers;

static void storeFree(CFTypeRef o)
{
	Store *s = (Store *)o;
	pthread_mutex_lock(&storeLock);
	for (Store **p = &watchers; *p; p = &(*p)->nextWatcher)
		if (*p == s) {
			*p = s->nextWatcher;
			break;
		}
	pthread_mutex_unlock(&storeLock);
	if (s->context.release && s->context.info)
		s->context.release(s->context.info);
	CFTypeRef refs[] = {s->name, s->watchedKeys, s->watchedPatterns, s->changed, s->snapshot, s->source, s->runLoops};
	for (size_t i = 0; i < sizeof(refs) / sizeof(*refs); i++)
		if (refs[i])
			CFRelease(refs[i]);
	if (s->queue)
		dispatch_release(s->queue);
}

static CFStringRef storeDescription(CFTypeRef o)
{
	return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SCDynamicStore %p> { name = %@ }"), o, ((Store *)o)->name);
}

SC_DEFINE_TYPE(SCDynamicStoreGetTypeID, "SCDynamicStore", storeFree, NULL, NULL, storeDescription)

static CFDictionaryRef copyAll(void)
{
	CFDictionaryRef state = _SCCopyLocalState();
	CFMutableDictionaryRef all = CFDictionaryCreateMutableCopy(NULL, 0, state);
	CFRelease(state);
	pthread_mutex_lock(&storeLock);
	if (localValues) {
		CFIndex n = CFDictionaryGetCount(localValues);
		const void **k = malloc(sizeof(void *) * n), **v = malloc(sizeof(void *) * n);
		CFDictionaryGetKeysAndValues(localValues, k, v);
		for (CFIndex i = 0; i < n; i++) {
			if (v[i] == kCFNull)
				CFDictionaryRemoveValue(all, k[i]);
			else
				CFDictionarySetValue(all, k[i], v[i]);
		}
		free(k);
		free(v);
	}
	pthread_mutex_unlock(&storeLock);
	return all;
}

SCDynamicStoreRef SCDynamicStoreCreateWithOptions(CFAllocatorRef allocator, CFStringRef name, CFDictionaryRef storeOptions,
    SCDynamicStoreCallBack callout, SCDynamicStoreContext *context)
{
	if (!name || CFGetTypeID(name) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	Store *s = (Store *)_SCCreateInstance(SCDynamicStoreGetTypeID(), sizeof(*s));
	s->name = CFStringCreateCopy(NULL, name);
	s->callout = callout;
	if (context) {
		s->context = *context;
		if (context->retain && context->info)
			s->context.info = (void *)context->retain(context->info);
	}
	s->changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	_SCErrorSet(kSCStatusOK);
	return (SCDynamicStoreRef)s;
}

SCDynamicStoreRef SCDynamicStoreCreate(CFAllocatorRef allocator, CFStringRef name, SCDynamicStoreCallBack callout,
    SCDynamicStoreContext *context)
{
	return SCDynamicStoreCreateWithOptions(allocator, name, NULL, callout, context);
}

static bool validStore(SCDynamicStoreRef s)
{
	if (s && CFGetTypeID(s) == SCDynamicStoreGetTypeID())
		return true;
	_SCErrorSet(kSCStatusNoStoreSession);
	return false;
}

CFPropertyListRef SCDynamicStoreCopyValue(SCDynamicStoreRef store, CFStringRef key)
{
	if (store && !validStore(store))
		return NULL;
	if (!key || CFGetTypeID(key) != CFStringGetTypeID()) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	CFDictionaryRef all = copyAll();
	CFPropertyListRef v = CFDictionaryGetValue(all, key);
	if (v)
		CFRetain(v);
	CFRelease(all);
	_SCErrorSet(v ? kSCStatusOK : kSCStatusNoKey);
	return v;
}

/* configd's patterns are POSIX extended regular expressions, matched against
 * the whole key. */
static bool compilePattern(CFStringRef pattern, regex_t *re)
{
	char buf[1024], anchored[1100];
	if (!CFStringGetCString(pattern, buf, sizeof(buf), kCFStringEncodingUTF8))
		return false;
	snprintf(anchored, sizeof(anchored), "^(%s)$", buf);
	return regcomp(re, anchored, REG_EXTENDED | REG_NOSUB) == 0;
}

static bool keyMatches(regex_t *re, CFStringRef key)
{
	char buf[1024];
	return CFStringGetCString(key, buf, sizeof(buf), kCFStringEncodingUTF8) && regexec(re, buf, 0, NULL, 0) == 0;
}

CFArrayRef SCDynamicStoreCopyKeyList(SCDynamicStoreRef store, CFStringRef pattern)
{
	if (store && !validStore(store))
		return NULL;
	regex_t re;
	if (!pattern || CFGetTypeID(pattern) != CFStringGetTypeID() || !compilePattern(pattern, &re)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	CFDictionaryRef all = copyAll();
	CFIndex n = CFDictionaryGetCount(all);
	const void **keys = malloc(sizeof(void *) * n);
	CFDictionaryGetKeysAndValues(all, keys, NULL);
	CFMutableArrayRef out = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	for (CFIndex i = 0; i < n; i++)
		if (keyMatches(&re, keys[i]))
			CFArrayAppendValue(out, keys[i]);
	free(keys);
	regfree(&re);
	CFRelease(all);
	_SCErrorSet(kSCStatusOK);
	return out;
}

static CFDictionaryRef copyMatching(CFDictionaryRef all, CFArrayRef keys, CFArrayRef patterns)
{
	CFMutableDictionaryRef out = newDict();
	for (CFIndex i = 0; keys && i < CFArrayGetCount(keys); i++) {
		CFTypeRef v = CFDictionaryGetValue(all, CFArrayGetValueAtIndex(keys, i));
		if (v)
			CFDictionarySetValue(out, CFArrayGetValueAtIndex(keys, i), v);
	}
	if (patterns && CFArrayGetCount(patterns)) {
		CFIndex n = CFDictionaryGetCount(all);
		const void **k = malloc(sizeof(void *) * n), **v = malloc(sizeof(void *) * n);
		CFDictionaryGetKeysAndValues(all, k, v);
		for (CFIndex p = 0; p < CFArrayGetCount(patterns); p++) {
			regex_t re;
			if (!compilePattern(CFArrayGetValueAtIndex(patterns, p), &re))
				continue;
			for (CFIndex i = 0; i < n; i++)
				if (keyMatches(&re, k[i]))
					CFDictionarySetValue(out, k[i], v[i]);
			regfree(&re);
		}
		free(k);
		free(v);
	}
	return out;
}

CFDictionaryRef SCDynamicStoreCopyMultiple(SCDynamicStoreRef store, CFArrayRef keys, CFArrayRef patterns)
{
	if (store && !validStore(store))
		return NULL;
	CFDictionaryRef all = copyAll();
	CFDictionaryRef out = copyMatching(all, keys, patterns);
	CFRelease(all);
	_SCErrorSet(kSCStatusOK);
	return out;
}

static void notifyLocalChange(CFStringRef key);

static Boolean setLocal(SCDynamicStoreRef store, CFStringRef key, CFPropertyListRef value, bool add)
{
	if (store && !validStore(store))
		return false;
	if (!key || CFGetTypeID(key) != CFStringGetTypeID() || (!value && add)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (add) {
		CFPropertyListRef have = SCDynamicStoreCopyValue(store, key);
		if (have) {
			CFRelease(have);
			_SCErrorSet(kSCStatusKeyExists);
			return false;
		}
	}
	pthread_mutex_lock(&storeLock);
	if (!localValues)
		localValues = newDict();
	CFDictionarySetValue(localValues, key, value ? value : kCFNull);
	pthread_mutex_unlock(&storeLock);
	notifyLocalChange(key);
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCDynamicStoreSetValue(SCDynamicStoreRef store, CFStringRef key, CFPropertyListRef value)
{
	if (!value) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	return setLocal(store, key, value, false);
}

Boolean SCDynamicStoreAddValue(SCDynamicStoreRef store, CFStringRef key, CFPropertyListRef value)
{
	return setLocal(store, key, value, true);
}

Boolean SCDynamicStoreAddTemporaryValue(SCDynamicStoreRef store, CFStringRef key, CFPropertyListRef value)
{
	return setLocal(store, key, value, true);
}

Boolean SCDynamicStoreSetMultiple(SCDynamicStoreRef store, CFDictionaryRef keysToSet, CFArrayRef keysToRemove,
    CFArrayRef keysToNotify)
{
	if (store && !validStore(store))
		return false;
	if (keysToSet) {
		CFIndex n = CFDictionaryGetCount(keysToSet);
		const void **k = malloc(sizeof(void *) * n), **v = malloc(sizeof(void *) * n);
		CFDictionaryGetKeysAndValues(keysToSet, k, v);
		for (CFIndex i = 0; i < n; i++)
			setLocal(store, k[i], v[i], false);
		free(k);
		free(v);
	}
	for (CFIndex i = 0; keysToRemove && i < CFArrayGetCount(keysToRemove); i++)
		setLocal(store, CFArrayGetValueAtIndex(keysToRemove, i), NULL, false);
	for (CFIndex i = 0; keysToNotify && i < CFArrayGetCount(keysToNotify); i++)
		notifyLocalChange(CFArrayGetValueAtIndex(keysToNotify, i));
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCDynamicStoreRemoveValue(SCDynamicStoreRef store, CFStringRef key)
{
	CFPropertyListRef have = SCDynamicStoreCopyValue(store, key);
	if (!have) {
		_SCErrorSet(kSCStatusNoKey);
		return false;
	}
	CFRelease(have);
	return setLocal(store, key, NULL, false);
}

Boolean SCDynamicStoreNotifyValue(SCDynamicStoreRef store, CFStringRef key)
{
	if (store && !validStore(store))
		return false;
	notifyLocalChange(key);
	_SCErrorSet(kSCStatusOK);
	return true;
}

/* ---- Notifications ---- */

static bool watches(Store *s, CFStringRef key)
{
	if (s->watchedKeys && CFArrayContainsValue(s->watchedKeys, CFRangeMake(0, CFArrayGetCount(s->watchedKeys)), key))
		return true;
	for (CFIndex i = 0; s->watchedPatterns && i < CFArrayGetCount(s->watchedPatterns); i++) {
		regex_t re;
		if (!compilePattern(CFArrayGetValueAtIndex(s->watchedPatterns, i), &re))
			continue;
		bool m = keyMatches(&re, key);
		regfree(&re);
		if (m)
			return true;
	}
	return false;
}

static void deliver(Store *s)
{
	CFArrayRef keys = NULL;
	pthread_mutex_lock(&storeLock);
	if (CFArrayGetCount(s->changed)) {
		keys = CFArrayCreateCopy(NULL, s->changed);
		CFArrayRemoveAllValues(s->changed);
	}
	pthread_mutex_unlock(&storeLock);
	if (keys && s->callout)
		s->callout((SCDynamicStoreRef)s, keys, s->context.info);
	if (keys)
		CFRelease(keys);
}

static void signalStore(Store *s)
{
	if (s->queue) {
		CFRetain(s);
		dispatch_async(s->queue, ^{
			deliver(s);
			CFRelease(s);
		});
	}
	if (s->source) {
		CFRunLoopSourceSignal(s->source);
		for (CFIndex i = 0; s->runLoops && i < CFArrayGetCount(s->runLoops); i++)
			CFRunLoopWakeUp((CFRunLoopRef)CFArrayGetValueAtIndex(s->runLoops, i));
	}
}

static void recordChanges(Store *s, CFArrayRef keys)
{
	bool any = false;
	pthread_mutex_lock(&storeLock);
	for (CFIndex i = 0; i < CFArrayGetCount(keys); i++) {
		CFStringRef k = CFArrayGetValueAtIndex(keys, i);
		if (!CFArrayContainsValue(s->changed, CFRangeMake(0, CFArrayGetCount(s->changed)), k)) {
			CFArrayAppendValue(s->changed, k);
			any = true;
		}
	}
	pthread_mutex_unlock(&storeLock);
	if (any)
		signalStore(s);
}

static void notifyLocalChange(CFStringRef key)
{
	CFArrayRef keys = CFArrayCreate(NULL, (const void **)&key, 1, &kCFTypeArrayCallBacks);
	pthread_mutex_lock(&storeLock);
	Store *list[64];
	int n = 0;
	for (Store *s = watchers; s && n < 64; s = s->nextWatcher)
		if (watches(s, key))
			list[n++] = (Store *)CFRetain(s);
	pthread_mutex_unlock(&storeLock);
	for (int i = 0; i < n; i++) {
		recordChanges(list[i], keys);
		CFRelease(list[i]);
	}
	CFRelease(keys);
}

/* Network changes: re-read the watched keys and report the ones that differ. */
static void networkChanged(void)
{
	pthread_mutex_lock(&storeLock);
	Store *list[64];
	int n = 0;
	for (Store *s = watchers; s && n < 64; s = s->nextWatcher)
		list[n++] = (Store *)CFRetain(s);
	pthread_mutex_unlock(&storeLock);
	if (!n)
		return;
	CFDictionaryRef all = copyAll();
	for (int i = 0; i < n; i++) {
		Store *s = list[i];
		CFDictionaryRef now = copyMatching(all, s->watchedKeys, s->watchedPatterns);
		CFMutableArrayRef changed = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
		CFDictionaryRef before = s->snapshot;
		CFDictionaryRef sides[] = {now, before};
		for (int side = 0; side < 2; side++) {
			CFDictionaryRef d = sides[side];
			CFIndex c = d ? CFDictionaryGetCount(d) : 0;
			const void **k = malloc(sizeof(void *) * (c ? c : 1));
			if (d)
				CFDictionaryGetKeysAndValues(d, k, NULL);
			for (CFIndex j = 0; j < c; j++) {
				CFTypeRef a = now ? CFDictionaryGetValue(now, k[j]) : NULL;
				CFTypeRef b = before ? CFDictionaryGetValue(before, k[j]) : NULL;
				if ((!a || !b || !CFEqual(a, b)) &&
				    !CFArrayContainsValue(changed, CFRangeMake(0, CFArrayGetCount(changed)), k[j]))
					CFArrayAppendValue(changed, k[j]);
			}
			free(k);
		}
		pthread_mutex_lock(&storeLock);
		if (s->snapshot)
			CFRelease(s->snapshot);
		s->snapshot = now;
		pthread_mutex_unlock(&storeLock);
		if (CFArrayGetCount(changed))
			recordChanges(s, changed);
		CFRelease(changed);
		CFRelease(s);
	}
	CFRelease(all);
}

static void startWatching(Store *s)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		_SCWatchNetworkChanges(^{
			networkChanged();
		});
	});
	CFDictionaryRef all = copyAll();
	CFDictionaryRef now = copyMatching(all, s->watchedKeys, s->watchedPatterns);
	CFRelease(all);
	pthread_mutex_lock(&storeLock);
	if (s->snapshot)
		CFRelease(s->snapshot);
	s->snapshot = now;
	if (!s->watching) {
		s->nextWatcher = watchers;
		watchers = s;
		s->watching = true;
	}
	pthread_mutex_unlock(&storeLock);
}

Boolean SCDynamicStoreSetNotificationKeys(SCDynamicStoreRef store, CFArrayRef keys, CFArrayRef patterns)
{
	if (!validStore(store))
		return false;
	Store *s = (Store *)store;
	pthread_mutex_lock(&storeLock);
	if (s->watchedKeys)
		CFRelease(s->watchedKeys);
	if (s->watchedPatterns)
		CFRelease(s->watchedPatterns);
	s->watchedKeys = keys ? CFArrayCreateCopy(NULL, keys) : NULL;
	s->watchedPatterns = patterns ? CFArrayCreateCopy(NULL, patterns) : NULL;
	pthread_mutex_unlock(&storeLock);
	startWatching(s);
	_SCErrorSet(kSCStatusOK);
	return true;
}

CFArrayRef SCDynamicStoreCopyNotifiedKeys(SCDynamicStoreRef store)
{
	if (!validStore(store))
		return NULL;
	Store *s = (Store *)store;
	pthread_mutex_lock(&storeLock);
	CFArrayRef keys = CFArrayCreateCopy(NULL, s->changed);
	CFArrayRemoveAllValues(s->changed);
	pthread_mutex_unlock(&storeLock);
	_SCErrorSet(kSCStatusOK);
	return keys;
}

static void sourcePerform(void *info)
{
	deliver((Store *)info);
}

static void sourceSchedule(void *info, CFRunLoopRef rl, CFStringRef mode)
{
	Store *s = info;
	pthread_mutex_lock(&storeLock);
	if (!s->runLoops)
		s->runLoops = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	CFArrayAppendValue(s->runLoops, rl);
	pthread_mutex_unlock(&storeLock);
}

static void sourceCancel(void *info, CFRunLoopRef rl, CFStringRef mode)
{
	Store *s = info;
	pthread_mutex_lock(&storeLock);
	CFIndex i = s->runLoops ? CFArrayGetFirstIndexOfValue(s->runLoops, CFRangeMake(0, CFArrayGetCount(s->runLoops)), rl) : kCFNotFound;
	if (i != kCFNotFound)
		CFArrayRemoveValueAtIndex(s->runLoops, i);
	pthread_mutex_unlock(&storeLock);
}

CFRunLoopSourceRef SCDynamicStoreCreateRunLoopSource(CFAllocatorRef allocator, SCDynamicStoreRef store, CFIndex order)
{
	if (!validStore(store))
		return NULL;
	Store *s = (Store *)store;
	if (s->queue) {
		_SCErrorSet(kSCStatusNotifierActive);
		return NULL;
	}
	if (!s->source) {
		CFRunLoopSourceContext ctx = {0, s, NULL, NULL, NULL, NULL, NULL, sourceSchedule, sourceCancel, sourcePerform};
		s->source = CFRunLoopSourceCreate(allocator, order, &ctx);
	}
	_SCErrorSet(kSCStatusOK);
	return (CFRunLoopSourceRef)CFRetain(s->source);
}

Boolean SCDynamicStoreSetDispatchQueue(SCDynamicStoreRef store, dispatch_queue_t queue)
{
	if (!validStore(store))
		return false;
	Store *s = (Store *)store;
	if (queue && (s->queue || s->source)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (s->queue)
		dispatch_release(s->queue);
	s->queue = queue;
	if (queue)
		dispatch_retain(queue);
	_SCErrorSet(kSCStatusOK);
	return true;
}

/* ---- Specific values ---- */

CFStringRef SCDynamicStoreCopyComputerName(SCDynamicStoreRef store, CFStringEncoding *nameEncoding)
{
	_SCErrorSet(kSCStatusOK);
	return _SCCopyComputerName(nameEncoding);
}

CFStringRef SCDynamicStoreCopyLocalHostName(SCDynamicStoreRef store)
{
	_SCErrorSet(kSCStatusOK);
	return _SCCopyLocalHostName();
}

/* SCDynamicStoreCopyConsoleUser and SCDynamicStoreCopyLocation are configd's
 * (SCDConsoleUser.c, SCLocation.c), over this store. */

CFDictionaryRef SCDynamicStoreCopyProxies(SCDynamicStoreRef store)
{
	CFDictionaryRef d = SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/Proxies"));
	_SCErrorSet(kSCStatusOK);
	return d;
}

/* Key creators configd defines in files that need its daemon (SCDHostName.c,
 * SCProxies.c); the rest are configd's own (SCDKeys.c, SCDConsoleUser.c, SCLocation.c). */
CFStringRef SCDynamicStoreKeyCreateComputerName(CFAllocatorRef allocator)
{
	return CFStringCreateWithFormat(allocator, NULL, CFSTR("%@/%@"), kSCDynamicStoreDomainSetup, kSCCompSystem);
}

CFStringRef SCDynamicStoreKeyCreateHostNames(CFAllocatorRef allocator)
{
	return CFStringCreateWithFormat(allocator, NULL, CFSTR("%@/%@/%@"), kSCDynamicStoreDomainSetup, kSCCompNetwork,
	    kSCCompHostNames);
}

CFStringRef SCDynamicStoreKeyCreateProxies(CFAllocatorRef allocator)
{
	return SCDynamicStoreKeyCreateNetworkGlobalEntity(allocator, kSCDynamicStoreDomainState, kSCEntNetProxies);
}
