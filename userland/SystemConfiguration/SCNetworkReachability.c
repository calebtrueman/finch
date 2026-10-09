/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * SCNetworkReachability over the kernel's routing table (docs/design/SECURITY.md).
 *
 * An address is reachable if the kernel has a route to it (a UDP socket
 * connects; nothing is sent); it's local if it's one of this machine's
 * addresses, direct if it's on a connected network (or loopback). A name is
 * looked up only when it's numeric or a loopback name ("localhost"), as
 * Apple's answers without waiting for DNS; otherwise it's reachable if there's
 * a default route. Scheduled targets are re-evaluated whenever the routing
 * socket reports a change, and their callbacks fire when the flags change.
 */
#include "SCFinch.h"
#include <arpa/inet.h>
#include <errno.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/route.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <unistd.h>

/* ---- The network change monitor ---- */

static pthread_mutex_t monitorLock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableArrayRef handlers;
static dispatch_source_t routeSource;
static dispatch_queue_t monitorQueue;

void _SCWatchNetworkChanges(void (^handler)(void))
{
	pthread_mutex_lock(&monitorLock);
	if (!handlers)
		handlers = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
	void (^copy)(void) = Block_copy(handler);
	CFArrayAppendValue(handlers, copy);
	Block_release(copy);
	if (!routeSource) {
		int fd = socket(PF_ROUTE, SOCK_RAW, 0);
		if (fd >= 0) {
			monitorQueue = dispatch_queue_create("com.apple.SystemConfiguration.finch.monitor", NULL);
			routeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, monitorQueue);
			dispatch_source_set_event_handler(routeSource, ^{
				char buf[4096];
				bool changed = false;
				while (recv(fd, buf, sizeof(buf), MSG_DONTWAIT) > 0)
					changed = true;
				if (!changed)
					return;
				pthread_mutex_lock(&monitorLock);
				CFArrayRef list = CFArrayCreateCopy(NULL, handlers);
				pthread_mutex_unlock(&monitorLock);
				for (CFIndex i = 0; i < CFArrayGetCount(list); i++)
					((void (^)(void))CFArrayGetValueAtIndex(list, i))();
				CFRelease(list);
			});
			dispatch_source_set_cancel_handler(routeSource, ^{
				close(fd);
			});
			dispatch_resume(routeSource);
		}
	}
	pthread_mutex_unlock(&monitorLock);
}

/* ---- Targets ---- */

enum { kTargetName, kTargetAddress, kTargetPair };

typedef struct {
	CFRuntimeBase base;
	int kind;
	char *name;
	struct sockaddr_storage local, remote;
	bool hasLocal, hasRemote;
	SCNetworkReachabilityCallBack callout;
	SCNetworkReachabilityContext context;
	dispatch_queue_t queue;
	CFRunLoopRef runLoop;
	CFStringRef runLoopMode;
	SCNetworkReachabilityFlags lastFlags;
	bool scheduled, haveFlags;
} Target;

static pthread_mutex_t targetLock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableArrayRef scheduledTargets;   /* not retained */

static void targetFree(CFTypeRef o)
{
	Target *t = (Target *)o;
	free(t->name);
	if (t->context.release && t->context.info)
		t->context.release(t->context.info);
	if (t->queue)
		dispatch_release(t->queue);
	if (t->runLoop)
		CFRelease(t->runLoop);
	if (t->runLoopMode)
		CFRelease(t->runLoopMode);
}

static CFStringRef targetDescription(CFTypeRef o)
{
	Target *t = (Target *)o;
	if (t->kind == kTargetName)
		return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SCNetworkReachability %p> {name = %s}"), o, t->name);
	char buf[INET6_ADDRSTRLEN] = "";
	const struct sockaddr *sa = (const struct sockaddr *)&t->remote;
	if (sa->sa_family == AF_INET)
		inet_ntop(AF_INET, &((const struct sockaddr_in *)sa)->sin_addr, buf, sizeof(buf));
	else if (sa->sa_family == AF_INET6)
		inet_ntop(AF_INET6, &((const struct sockaddr_in6 *)sa)->sin6_addr, buf, sizeof(buf));
	return CFStringCreateWithFormat(NULL, NULL, CFSTR("<SCNetworkReachability %p> {address = %s}"), o, buf);
}

SC_DEFINE_TYPE(SCNetworkReachabilityGetTypeID, "SCNetworkReachability", targetFree, NULL, NULL, targetDescription)

static bool copyAddress(struct sockaddr_storage *dst, const struct sockaddr *src)
{
	if (!src || (src->sa_family != AF_INET && src->sa_family != AF_INET6))
		return false;
	size_t len = src->sa_family == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
	memset(dst, 0, sizeof(*dst));
	memcpy(dst, src, len);
	dst->ss_len = (uint8_t)len;
	return true;
}

SCNetworkReachabilityRef SCNetworkReachabilityCreateWithAddress(CFAllocatorRef allocator, const struct sockaddr *address)
{
	struct sockaddr_storage ss;
	if (!copyAddress(&ss, address)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	Target *t = (Target *)_SCCreateInstance(SCNetworkReachabilityGetTypeID(), sizeof(*t));
	t->kind = kTargetAddress;
	t->remote = ss;
	t->hasRemote = true;
	return (SCNetworkReachabilityRef)t;
}

SCNetworkReachabilityRef SCNetworkReachabilityCreateWithAddressPair(CFAllocatorRef allocator,
    const struct sockaddr *localAddress, const struct sockaddr *remoteAddress)
{
	if (!localAddress && !remoteAddress) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	Target *t = (Target *)_SCCreateInstance(SCNetworkReachabilityGetTypeID(), sizeof(*t));
	t->kind = kTargetPair;
	t->hasLocal = copyAddress(&t->local, localAddress);
	t->hasRemote = copyAddress(&t->remote, remoteAddress);
	if ((localAddress && !t->hasLocal) || (remoteAddress && !t->hasRemote)) {
		CFRelease(t);
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	return (SCNetworkReachabilityRef)t;
}

SCNetworkReachabilityRef SCNetworkReachabilityCreateWithName(CFAllocatorRef allocator, const char *nodename)
{
	if (!nodename || !*nodename) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return NULL;
	}
	Target *t = (Target *)_SCCreateInstance(SCNetworkReachabilityGetTypeID(), sizeof(*t));
	t->kind = kTargetName;
	t->name = strdup(nodename);
	/* A numeric name is an address. */
	struct addrinfo hints = {.ai_flags = AI_NUMERICHOST}, *res = NULL;
	if (getaddrinfo(nodename, NULL, &hints, &res) == 0 && res) {
		t->hasRemote = copyAddress(&t->remote, res->ai_addr);
		freeaddrinfo(res);
	}
	return (SCNetworkReachabilityRef)t;
}

static Target *valid(SCNetworkReachabilityRef r)
{
	if (r && CFGetTypeID(r) == SCNetworkReachabilityGetTypeID())
		return (Target *)r;
	_SCErrorSet(kSCStatusInvalidArgument);
	return NULL;
}

/* ---- Evaluation ---- */

static bool isLoopback(const struct sockaddr *sa)
{
	if (sa->sa_family == AF_INET)
		return (ntohl(((const struct sockaddr_in *)sa)->sin_addr.s_addr) >> 24) == 127;
	return IN6_IS_ADDR_LOOPBACK(&((const struct sockaddr_in6 *)sa)->sin6_addr);
}

static bool sameAddress(const struct sockaddr *a, const struct sockaddr *b)
{
	if (a->sa_family != b->sa_family)
		return false;
	if (a->sa_family == AF_INET)
		return ((const struct sockaddr_in *)a)->sin_addr.s_addr == ((const struct sockaddr_in *)b)->sin_addr.s_addr;
	struct in6_addr x = ((const struct sockaddr_in6 *)a)->sin6_addr, y = ((const struct sockaddr_in6 *)b)->sin6_addr;
	if (IN6_IS_ADDR_LINKLOCAL(&x))
		x.s6_addr[2] = x.s6_addr[3] = 0;
	if (IN6_IS_ADDR_LINKLOCAL(&y))
		y.s6_addr[2] = y.s6_addr[3] = 0;
	return memcmp(&x, &y, sizeof(x)) == 0;
}

static bool onLink(const struct sockaddr *target, const struct sockaddr *addr, const struct sockaddr *mask)
{
	if (!mask || target->sa_family != addr->sa_family)
		return false;
	const uint8_t *t, *a, *m;
	size_t n;
	if (target->sa_family == AF_INET) {
		t = (const uint8_t *)&((const struct sockaddr_in *)target)->sin_addr;
		a = (const uint8_t *)&((const struct sockaddr_in *)addr)->sin_addr;
		m = (const uint8_t *)&((const struct sockaddr_in *)mask)->sin_addr;
		n = 4;
	} else {
		t = (const uint8_t *)&((const struct sockaddr_in6 *)target)->sin6_addr;
		a = (const uint8_t *)&((const struct sockaddr_in6 *)addr)->sin6_addr;
		m = (const uint8_t *)&((const struct sockaddr_in6 *)mask)->sin6_addr;
		n = 16;
	}
	bool any = false;
	for (size_t i = 0; i < n; i++) {
		if ((t[i] & m[i]) != (a[i] & m[i]))
			return false;
		any = any || m[i];
	}
	return any;
}

static bool routeTo(const struct sockaddr *sa)
{
	int s = socket(sa->sa_family, SOCK_DGRAM, 0);
	if (s < 0)
		return false;
	struct sockaddr_storage to;
	copyAddress(&to, sa);
	if (to.ss_family == AF_INET && ((struct sockaddr_in *)&to)->sin_port == 0)
		((struct sockaddr_in *)&to)->sin_port = htons(9);
	if (to.ss_family == AF_INET6 && ((struct sockaddr_in6 *)&to)->sin6_port == 0)
		((struct sockaddr_in6 *)&to)->sin6_port = htons(9);
	bool ok = connect(s, (struct sockaddr *)&to, to.ss_len) == 0;
	close(s);
	return ok;
}

static SCNetworkReachabilityFlags addressFlags(const struct sockaddr *sa)
{
	if (!routeTo(sa))
		return 0;
	SCNetworkReachabilityFlags f = kSCNetworkReachabilityFlagsReachable;
	if (isLoopback(sa))
		return f | kSCNetworkReachabilityFlagsIsLocalAddress | kSCNetworkReachabilityFlagsIsDirect;
	struct ifaddrs *ifa = NULL;
	if (getifaddrs(&ifa) == 0) {
		for (struct ifaddrs *i = ifa; i; i = i->ifa_next) {
			if (!i->ifa_addr || !(i->ifa_flags & IFF_UP))
				continue;
			if (sameAddress(sa, i->ifa_addr))
				f |= kSCNetworkReachabilityFlagsIsLocalAddress | kSCNetworkReachabilityFlagsIsDirect;
			else if (!(i->ifa_flags & IFF_LOOPBACK) && onLink(sa, i->ifa_addr, i->ifa_netmask))
				f |= kSCNetworkReachabilityFlagsIsDirect;
		}
		freeifaddrs(ifa);
	}
	return f;
}

static bool loopbackName(const char *name)
{
	size_t n = strlen(name);
	while (n && name[n - 1] == '.')
		n--;
	return (n == 9 && !strncasecmp(name, "localhost", 9)) ||
	    (n > 10 && !strncasecmp(name + n - 10, ".localhost", 10));
}

static SCNetworkReachabilityFlags evaluate(Target *t)
{
	if (t->hasRemote)
		return addressFlags((const struct sockaddr *)&t->remote);
	if (t->kind == kTargetPair && t->hasLocal)
		return addressFlags((const struct sockaddr *)&t->local);
	if (t->kind == kTargetName) {
		if (loopbackName(t->name)) {
			struct sockaddr_in lo = {.sin_len = sizeof(lo), .sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
			return addressFlags((struct sockaddr *)&lo);
		}
		/* Reachable if packets for it would leave: a default route exists. */
		struct sockaddr_in v4 = {.sin_len = sizeof(v4), .sin_family = AF_INET};
		inet_pton(AF_INET, "192.0.2.1", &v4.sin_addr);
		struct sockaddr_in6 v6 = {.sin6_len = sizeof(v6), .sin6_family = AF_INET6};
		inet_pton(AF_INET6, "2001:db8::1", &v6.sin6_addr);
		return routeTo((struct sockaddr *)&v4) || routeTo((struct sockaddr *)&v6) ? kSCNetworkReachabilityFlagsReachable : 0;
	}
	return 0;
}

Boolean SCNetworkReachabilityGetFlags(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags *flags)
{
	Target *t = valid(target);
	if (!t || !flags)
		return false;
	*flags = evaluate(t);
	_SCErrorSet(kSCStatusOK);
	return true;
}

/* ---- Callbacks ---- */

static void deliver(Target *t, SCNetworkReachabilityFlags flags)
{
	SCNetworkReachabilityCallBack fn = t->callout;
	if (!fn)
		return;
	CFRetain(t);
	void (^call)(void) = ^{
		fn((SCNetworkReachabilityRef)t, flags, t->context.info);
		CFRelease(t);
	};
	if (t->queue)
		dispatch_async(t->queue, call);
	else if (t->runLoop) {
		CFRunLoopPerformBlock(t->runLoop, t->runLoopMode, call);
		CFRunLoopWakeUp(t->runLoop);
	} else
		CFRelease(t);
}

static void reevaluateAll(void)
{
	pthread_mutex_lock(&targetLock);
	CFIndex n = scheduledTargets ? CFArrayGetCount(scheduledTargets) : 0;
	Target **list = malloc(sizeof(Target *) * (n ? n : 1));
	for (CFIndex i = 0; i < n; i++)
		list[i] = (Target *)CFRetain(CFArrayGetValueAtIndex(scheduledTargets, i));
	pthread_mutex_unlock(&targetLock);
	for (CFIndex i = 0; i < n; i++) {
		Target *t = list[i];
		SCNetworkReachabilityFlags f = evaluate(t);
		pthread_mutex_lock(&targetLock);
		bool changed = t->scheduled && (!t->haveFlags || f != t->lastFlags);
		t->lastFlags = f;
		t->haveFlags = true;
		pthread_mutex_unlock(&targetLock);
		if (changed)
			deliver(t, f);
		CFRelease(t);
	}
	free(list);
}

static void schedule(Target *t)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		_SCWatchNetworkChanges(^{
			reevaluateAll();
		});
	});
	SCNetworkReachabilityFlags f = evaluate(t);
	pthread_mutex_lock(&targetLock);
	if (!scheduledTargets) {
		CFArrayCallBacks cb = {0};
		scheduledTargets = CFArrayCreateMutable(NULL, 0, &cb);
	}
	if (!t->scheduled)
		CFArrayAppendValue(scheduledTargets, t);
	t->scheduled = true;
	t->lastFlags = f;
	t->haveFlags = true;
	pthread_mutex_unlock(&targetLock);
	/* A name target reports once its "resolution" is done, as Apple's does
	 * after DNS; an address target only when something changes. */
	if (t->kind == kTargetName && !t->hasRemote)
		deliver(t, f);
}

static void unschedule(Target *t)
{
	pthread_mutex_lock(&targetLock);
	if (t->scheduled && scheduledTargets) {
		CFIndex i = CFArrayGetFirstIndexOfValue(scheduledTargets, CFRangeMake(0, CFArrayGetCount(scheduledTargets)), t);
		if (i != kCFNotFound)
			CFArrayRemoveValueAtIndex(scheduledTargets, i);
	}
	t->scheduled = false;
	pthread_mutex_unlock(&targetLock);
}

Boolean SCNetworkReachabilitySetCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityCallBack callout,
    SCNetworkReachabilityContext *context)
{
	Target *t = valid(target);
	if (!t)
		return false;
	if (t->context.release && t->context.info)
		t->context.release(t->context.info);
	memset(&t->context, 0, sizeof(t->context));
	t->callout = callout;
	if (context) {
		t->context = *context;
		if (context->retain && context->info)
			t->context.info = (void *)context->retain(context->info);
	}
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCNetworkReachabilitySetDispatchQueue(SCNetworkReachabilityRef target, dispatch_queue_t queue)
{
	Target *t = valid(target);
	if (!t)
		return false;
	if (queue && (t->queue || t->runLoop)) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (!queue) {
		unschedule(t);
		if (t->queue)
			dispatch_release(t->queue);
		t->queue = NULL;
	} else {
		dispatch_retain(queue);
		t->queue = queue;
		schedule(t);
	}
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCNetworkReachabilityScheduleWithRunLoop(SCNetworkReachabilityRef target, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
	Target *t = valid(target);
	if (!t)
		return false;
	if (!runLoop || !runLoopMode || t->queue) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	if (t->runLoop)
		CFRelease(t->runLoop);
	if (t->runLoopMode)
		CFRelease(t->runLoopMode);
	t->runLoop = (CFRunLoopRef)CFRetain(runLoop);
	t->runLoopMode = CFRetain(runLoopMode);
	schedule(t);
	_SCErrorSet(kSCStatusOK);
	return true;
}

Boolean SCNetworkReachabilityUnscheduleFromRunLoop(SCNetworkReachabilityRef target, CFRunLoopRef runLoop, CFStringRef runLoopMode)
{
	Target *t = valid(target);
	if (!t)
		return false;
	if (!t->runLoop) {
		_SCErrorSet(kSCStatusInvalidArgument);
		return false;
	}
	unschedule(t);
	CFRelease(t->runLoop);
	t->runLoop = NULL;
	if (t->runLoopMode)
		CFRelease(t->runLoopMode);
	t->runLoopMode = NULL;
	_SCErrorSet(kSCStatusOK);
	return true;
}

/* The deprecated synchronous calls. */
Boolean SCNetworkCheckReachabilityByAddress(const struct sockaddr *address, socklen_t addrlen, SCNetworkConnectionFlags *flags)
{
	SCNetworkReachabilityRef r = SCNetworkReachabilityCreateWithAddress(NULL, address);
	if (!r)
		return false;
	Boolean ok = SCNetworkReachabilityGetFlags(r, flags);
	CFRelease(r);
	return ok;
}

Boolean SCNetworkCheckReachabilityByName(const char *nodename, SCNetworkConnectionFlags *flags)
{
	SCNetworkReachabilityRef r = SCNetworkReachabilityCreateWithName(NULL, nodename);
	if (!r)
		return false;
	Boolean ok = SCNetworkReachabilityGetFlags(r, flags);
	CFRelease(r);
	return ok;
}
