/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-sysconfig-test: SystemConfiguration, as apps use it. Schema
 * constants, store keys, error strings, the dynamic store (computer name,
 * console user, proxies, network state), reachability, preferences (from a
 * file the test writes), network sets, services and interfaces. Prints
 * shapes and status codes, not machine-specific values: run it against
 * Apple's framework and Finch's (DYLD_FRAMEWORK_PATH) and diff all but the
 * first line.
 */
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <pwd.h>
#include <unistd.h>

static NSString *
typeName(id v)
{
    if (!v)
        return @"nil";
    CFTypeID t = CFGetTypeID((__bridge CFTypeRef)v);
    if (t == CFStringGetTypeID()) return @"string";
    if (t == CFNumberGetTypeID()) return @"number";
    if (t == CFBooleanGetTypeID()) return @"bool";
    if (t == CFDataGetTypeID()) return @"data";
    if (t == CFArrayGetTypeID()) return @"array";
    if (t == CFDictionaryGetTypeID()) return @"dict";
    return @"other";
}

static void
constants(void)
{
    printf("== constants\n");
    static const char *names[] = {
        "kCFErrorDomainSystemConfiguration", "kSCDynamicStoreDomainState", "kSCDynamicStoreDomainSetup",
        "kSCDynamicStoreDomainFile", "kSCDynamicStoreDomainPlugin", "kSCDynamicStoreDomainPrefs",
        "kSCCompNetwork", "kSCCompService", "kSCCompInterface", "kSCCompGlobal", "kSCCompHostNames",
        "kSCCompSystem", "kSCCompUsers", "kSCCompAnyRegex", "kSCEntNetIPv4", "kSCEntNetIPv6", "kSCEntNetDNS",
        "kSCEntNetLink", "kSCEntNetInterface", "kSCEntNetEthernet", "kSCEntNetAirPort", "kSCEntNetProxies",
        "kSCPropNetIPv4Addresses", "kSCPropNetIPv4SubnetMasks", "kSCPropNetIPv4Router", "kSCPropNetIPv6Addresses",
        "kSCPropNetIPv6Flags", "kSCPropNetDNSServerAddresses", "kSCPropNetDNSDomainName", "kSCPropNetDNSSearchDomains",
        "kSCPropNetInterfaceType", "kSCPropNetInterfaceHardware", "kSCPropNetInterfaceDeviceName",
        "kSCPropNetLinkActive", "kSCPropNetProxiesHTTPEnable", "kSCPropNetProxiesHTTPProxy",
        "kSCPropNetProxiesHTTPPort", "kSCPropNetProxiesHTTPSEnable", "kSCPropNetProxiesHTTPSProxy",
        "kSCPropNetProxiesHTTPSPort", "kSCPropNetProxiesExceptionsList", "kSCPropUserDefinedName",
        "kSCPropSystemComputerName", "kSCPropSystemComputerNameEncoding", "kSCPropNetLocalHostName",
        "kSCPrefCurrentSet", "kSCPrefNetworkServices", "kSCPrefSets", "kSCPrefSystem",
        "kSCNetworkInterfaceTypeEthernet", "kSCNetworkInterfaceTypeIEEE80211", "kSCNetworkInterfaceTypeIPv4",
        "kSCNetworkInterfaceTypePPP", "kSCNetworkInterfaceTypeBond", "kSCNetworkInterfaceTypeBridge",
        "kSCNetworkInterfaceTypeVLAN", "kSCNetworkInterfaceTypeL2TP", "kSCNetworkInterfaceTypeIPSec",
        "kSCNetworkProtocolTypeIPv4", "kSCNetworkProtocolTypeDNS", "kSCNetworkProtocolTypeProxies",
        "kSCValNetInterfaceTypeEthernet", "kSCValNetIPv4ConfigMethodDHCP", "kSCPropNetIPv4ConfigMethod",
        "kSCResvLink", "kSCResvInactive", "kSCPropMACAddress",
    };
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        CFStringRef *p = dlsym(RTLD_DEFAULT, names[i]);
        printf("%s = %s\n", names[i], p ? [(__bridge NSString *)*p UTF8String] : "(missing)");
    }
}

static void
keys(void)
{
    printf("== keys\n");
    NSString *k;
    k = CFBridgingRelease(SCDynamicStoreKeyCreateNetworkServiceEntity(NULL, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv4));
    printf("service entity %s\n", k.UTF8String);
    k = CFBridgingRelease(SCDynamicStoreKeyCreateNetworkServiceEntity(NULL, kSCDynamicStoreDomainSetup, CFSTR("ABC"), NULL));
    printf("service %s\n", k.UTF8String);
    k = CFBridgingRelease(SCDynamicStoreKeyCreateNetworkInterfaceEntity(NULL, kSCDynamicStoreDomainState, CFSTR("en0"), kSCEntNetLink));
    printf("interface entity %s\n", k.UTF8String);
    k = CFBridgingRelease(SCDynamicStoreKeyCreateNetworkGlobalEntity(NULL, kSCDynamicStoreDomainState, kSCEntNetDNS));
    printf("global entity %s\n", k.UTF8String);
    k = CFBridgingRelease(SCDynamicStoreKeyCreateNetworkInterface(NULL, kSCDynamicStoreDomainState));
    printf("interface list %s\n", k.UTF8String);
    k = CFBridgingRelease(SCDynamicStoreKeyCreate(NULL, CFSTR("%@/%@/%d"), kSCDynamicStoreDomainState, CFSTR("Test"), 42));
    printf("formatted %s\n", k.UTF8String);
    k = CFBridgingRelease(SCDynamicStoreKeyCreateComputerName(NULL));
    printf("computer name %s\n", k.UTF8String);
    k = CFBridgingRelease(SCDynamicStoreKeyCreateConsoleUser(NULL));
    printf("console user %s\n", k.UTF8String);
    k = CFBridgingRelease(SCDynamicStoreKeyCreateHostNames(NULL));
    printf("host names %s\n", k.UTF8String);
    k = CFBridgingRelease(SCDynamicStoreKeyCreateLocation(NULL));
    printf("location %s\n", k.UTF8String);
    k = CFBridgingRelease(SCDynamicStoreKeyCreateProxies(NULL));
    printf("proxies %s\n", k.UTF8String);
}

static void
errors(void)
{
    printf("== errors\n");
    int codes[] = { kSCStatusOK, kSCStatusFailed, kSCStatusInvalidArgument, kSCStatusAccessError, kSCStatusNoKey,
                    kSCStatusKeyExists, kSCStatusLocked, kSCStatusNeedLock, kSCStatusNoStoreSession,
                    kSCStatusNoStoreServer, kSCStatusNotifierActive, kSCStatusNoPrefsSession, kSCStatusPrefsBusy,
                    kSCStatusNoConfigFile, kSCStatusNoLink, kSCStatusStale, kSCStatusMaxLink, kSCStatusReachabilityUnknown,
                    kSCStatusConnectionNoService, kSCStatusConnectionIgnore, 2, 9999 };
    for (size_t i = 0; i < sizeof codes / sizeof *codes; i++)
        printf("%d: %s\n", codes[i], SCErrorString(codes[i]));
    NSError *e = CFBridgingRelease(SCCopyLastError());
    printf("last error domain %s\n", e.domain.UTF8String);
}

static void
store(void)
{
    printf("== dynamic store\n");
    SCDynamicStoreRef s = SCDynamicStoreCreate(NULL, CFSTR("finch-sysconfig-test"), NULL, NULL);
    printf("create %d type %d\n", s != NULL, s && CFGetTypeID(s) == SCDynamicStoreGetTypeID());
    CFStringEncoding enc = 0xffff;
    NSString *name = CFBridgingRelease(SCDynamicStoreCopyComputerName(s, &enc));
    printf("computer name nonempty %d encoding set %d\n", name.length > 0, enc != 0xffff);
    NSString *name2 = CFBridgingRelease(SCDynamicStoreCopyComputerName(NULL, NULL));
    printf("computer name without store same %d\n", [name isEqual:name2]);
    NSString *local = CFBridgingRelease(SCDynamicStoreCopyLocalHostName(s));
    printf("local host name nonempty %d no dots %d\n", local.length > 0, [local rangeOfString:@"."].location == NSNotFound);
    uid_t uid = 99999;
    gid_t gid = 99999;
    NSString *user = CFBridgingRelease(SCDynamicStoreCopyConsoleUser(s, &uid, &gid));
    struct passwd *pw = user ? getpwnam(user.UTF8String) : NULL;
    printf("console user consistent %d\n", user == nil || (pw && pw->pw_uid == uid && pw->pw_gid == gid));
    NSDictionary *proxies = CFBridgingRelease(SCDynamicStoreCopyProxies(s));
    id http = proxies[(id)kSCPropNetProxiesHTTPEnable];
    printf("proxies %s http enable %s\n", typeName(proxies).UTF8String, http ? typeName(http).UTF8String : "number");

    NSString *gkey = CFBridgingRelease(SCDynamicStoreKeyCreateNetworkGlobalEntity(NULL, kSCDynamicStoreDomainState, kSCEntNetIPv4));
    NSDictionary *global = CFBridgingRelease(SCDynamicStoreCopyValue(s, (__bridge CFStringRef)gkey));
    printf("global ipv4 consistent %d\n", global == nil || [global[@"PrimaryInterface"] isKindOfClass:[NSString class]]);
    NSString *ckey = CFBridgingRelease(SCDynamicStoreKeyCreateComputerName(NULL));
    NSDictionary *cn = CFBridgingRelease(SCDynamicStoreCopyValue(s, (__bridge CFStringRef)ckey));
    printf("computer name key %s has name %d\n", typeName(cn).UTF8String, [cn[(id)kSCPropSystemComputerName] isEqual:name]);
    NSString *ukey = CFBridgingRelease(SCDynamicStoreKeyCreateConsoleUser(NULL));
    NSDictionary *cu = CFBridgingRelease(SCDynamicStoreCopyValue(s, (__bridge CFStringRef)ukey));
    printf("console user key consistent %d\n", (cu == nil) == (user == nil));

    NSString *missing = @"State:/Finch/Test/Nonexistent";
    id none = CFBridgingRelease(SCDynamicStoreCopyValue(s, (__bridge CFStringRef)missing));
    printf("missing %s error %d\n", typeName(none).UTF8String, SCError());

    NSString *ifkey = CFBridgingRelease(SCDynamicStoreKeyCreateNetworkInterface(NULL, kSCDynamicStoreDomainState));
    NSDictionary *ifs = CFBridgingRelease(SCDynamicStoreCopyValue(s, (__bridge CFStringRef)ifkey));
    NSArray *ifnames = ifs[@"Interfaces"];
    printf("interfaces %s list %s has lo0 %d\n", typeName(ifs).UTF8String, typeName(ifnames).UTF8String, [ifnames containsObject:@"lo0"]);
    NSString *loKey = CFBridgingRelease(SCDynamicStoreKeyCreateNetworkInterfaceEntity(NULL, kSCDynamicStoreDomainState, CFSTR("lo0"), kSCEntNetIPv4));
    NSDictionary *lo = CFBridgingRelease(SCDynamicStoreCopyValue(s, (__bridge CFStringRef)loKey));
    printf("lo0 ipv4 %s addresses %s has 127.0.0.1 %d masks %s\n", typeName(lo).UTF8String, typeName(lo[@"Addresses"]).UTF8String,
           [lo[@"Addresses"] containsObject:@"127.0.0.1"], typeName(lo[@"SubnetMasks"]).UTF8String);

    NSString *pattern = CFBridgingRelease(SCDynamicStoreKeyCreateNetworkInterfaceEntity(NULL, kSCDynamicStoreDomainState, kSCCompAnyRegex, kSCEntNetIPv4));
    NSArray *list = CFBridgingRelease(SCDynamicStoreCopyKeyList(s, (__bridge CFStringRef)pattern));
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"^%@$", pattern] options:0 error:nil];
    bool allMatch = true;
    for (NSString *key in list)
        allMatch = allMatch && [re numberOfMatchesInString:key options:0 range:NSMakeRange(0, key.length)] == 1;
    printf("key list %s all match %d has lo0 %d\n", typeName(list).UTF8String, allMatch, [list containsObject:loKey]);
    NSDictionary *multi = CFBridgingRelease(SCDynamicStoreCopyMultiple(s, (__bridge CFArrayRef) @[ ckey ], (__bridge CFArrayRef) @[ pattern ]));
    printf("multiple %s consistent %d\n", typeName(multi).UTF8String,
           multi.count == list.count + (cn ? 1 : 0) && (cn == nil || multi[ckey] != nil));
    NSArray *none2 = CFBridgingRelease(SCDynamicStoreCopyKeyList(s, CFSTR("^State:/Finch/Nothing.*")));
    printf("empty key list %s %lu\n", typeName(none2).UTF8String, (unsigned long)none2.count);

    printf("notification keys %d\n", SCDynamicStoreSetNotificationKeys(s, (__bridge CFArrayRef) @[ ckey ], (__bridge CFArrayRef) @[ pattern ]));
    NSArray *changed = CFBridgingRelease(SCDynamicStoreCopyNotifiedKeys(s));
    printf("notified keys %s %lu\n", typeName(changed).UTF8String, (unsigned long)changed.count);
    CFRunLoopSourceRef src = SCDynamicStoreCreateRunLoopSource(NULL, s, 0);
    printf("run loop source %d\n", src != NULL);
    if (src)
        CFRelease(src);
    SCDynamicStoreRef q = SCDynamicStoreCreate(NULL, CFSTR("finch-sysconfig-test-q"), NULL, NULL);
    dispatch_queue_t queue = dispatch_queue_create("sc", NULL);
    printf("dispatch queue %d", SCDynamicStoreSetDispatchQueue(q, queue));
    printf(" clear %d\n", SCDynamicStoreSetDispatchQueue(q, NULL));
    CFRelease(q);
    CFRelease(s);
}

static const char *
flagsText(SCNetworkReachabilityFlags f)
{
    static char buf[64];
    snprintf(buf, sizeof buf, "%c%c%c%c%c%c%c",
             (f & kSCNetworkReachabilityFlagsReachable) ? 'R' : '-',
             (f & kSCNetworkReachabilityFlagsTransientConnection) ? 't' : '-',
             (f & kSCNetworkReachabilityFlagsConnectionRequired) ? 'c' : '-',
             (f & kSCNetworkReachabilityFlagsConnectionOnTraffic) ? 'C' : '-',
             (f & kSCNetworkReachabilityFlagsInterventionRequired) ? 'i' : '-',
             (f & kSCNetworkReachabilityFlagsIsLocalAddress) ? 'l' : '-',
             (f & kSCNetworkReachabilityFlagsIsDirect) ? 'd' : '-');
    return buf;
}

static int callbacks;
static SCNetworkReachabilityFlags lastFlags;

static void
reachCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info)
{
    callbacks++;
    lastFlags = flags;
    dispatch_semaphore_signal((__bridge dispatch_semaphore_t)info);
}

static void
reachability(void)
{
    printf("== reachability\n");
    struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET };
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    SCNetworkReachabilityRef r = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&a);
    printf("create %d type %d\n", r != NULL, r && CFGetTypeID(r) == SCNetworkReachabilityGetTypeID());
    SCNetworkReachabilityFlags f = 0;
    printf("loopback %d %s\n", SCNetworkReachabilityGetFlags(r, &f), flagsText(f));
    struct sockaddr_in6 a6 = { .sin6_len = sizeof a6, .sin6_family = AF_INET6, .sin6_addr = IN6ADDR_LOOPBACK_INIT };
    SCNetworkReachabilityRef r6 = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&a6);
    f = 0;
    printf("loopback6 %d %s\n", SCNetworkReachabilityGetFlags(r6, &f), flagsText(f));
    SCNetworkReachabilityRef ln = SCNetworkReachabilityCreateWithName(NULL, "localhost");
    f = 0;
    printf("localhost %d %s\n", SCNetworkReachabilityGetFlags(ln, &f), flagsText(f));
    SCNetworkReachabilityRef bad = SCNetworkReachabilityCreateWithName(NULL, "finch-nonexistent.invalid");
    f = 0;
    printf("invalid name %d %s\n", SCNetworkReachabilityGetFlags(bad, &f), flagsText(f));
    struct sockaddr_in local = { .sin_len = sizeof local, .sin_family = AF_INET };
    inet_pton(AF_INET, "127.0.0.1", &local.sin_addr);
    SCNetworkReachabilityRef pair = SCNetworkReachabilityCreateWithAddressPair(NULL, (struct sockaddr *)&local, (struct sockaddr *)&a);
    f = 0;
    printf("pair %d", pair != NULL);
    if (pair)
        printf(" %d %s", SCNetworkReachabilityGetFlags(pair, &f), flagsText(f));
    printf("\n");

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    SCNetworkReachabilityContext ctx = { 0, (__bridge void *)sem, NULL, NULL, NULL };
    printf("set callback %d\n", SCNetworkReachabilitySetCallback(r, reachCallback, &ctx));
    dispatch_queue_t queue = dispatch_queue_create("reach", NULL);
    printf("dispatch queue %d\n", SCNetworkReachabilitySetDispatchQueue(r, queue));
    long waited = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    printf("callback %d flags %s\n", waited == 0 && callbacks > 0, flagsText(lastFlags));
    printf("clear queue %d\n", SCNetworkReachabilitySetDispatchQueue(r, NULL));
    printf("schedule %d", SCNetworkReachabilityScheduleWithRunLoop(r, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode));
    printf(" unschedule %d\n", SCNetworkReachabilityUnscheduleFromRunLoop(r, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode));
    printf("clear callback %d\n", SCNetworkReachabilitySetCallback(r, NULL, NULL));
    CFRelease(r);
    CFRelease(r6);
    CFRelease(ln);
    CFRelease(bad);
    if (pair)
        CFRelease(pair);
}

static void
preferences(void)
{
    printf("== preferences\n");
    NSString *path = [NSString stringWithFormat:@"%@/finch-sysconfig-test-%d.plist", NSTemporaryDirectory(), getpid()];
    NSDictionary *plist = @{
        @"CurrentSet" : @"/Sets/SET1",
        @"NetworkServices" : @{
            @"SVC1" : @{
                @"UserDefinedName" : @"Finch Ethernet",
                @"Interface" : @{ @"DeviceName" : @"en0", @"Hardware" : @"Ethernet", @"Type" : @"Ethernet", @"UserDefinedName" : @"Ethernet" },
                @"IPv4" : @{ @"ConfigMethod" : @"DHCP" },
                @"DNS" : @{},
            },
            @"SVC2" : @{
                @"UserDefinedName" : @"Finch Disabled",
                @"__INACTIVE__" : @1,
                @"Interface" : @{ @"DeviceName" : @"en1", @"Hardware" : @"Ethernet", @"Type" : @"Ethernet", @"UserDefinedName" : @"Ethernet 2" },
            },
        },
        @"Sets" : @{
            @"SET1" : @{
                @"UserDefinedName" : @"Automatic",
                @"Network" : @{
                    @"Service" : @{ @"SVC1" : @{ @"__LINK__" : @"/NetworkServices/SVC1" }, @"SVC2" : @{ @"__LINK__" : @"/NetworkServices/SVC2" } },
                    @"Global" : @{ @"IPv4" : @{ @"ServiceOrder" : @[ @"SVC1", @"SVC2" ] } },
                },
            },
        },
        @"System" : @{ @"System" : @{ @"ComputerName" : @"Finch Test", @"ComputerNameEncoding" : @0 },
                       @"Network" : @{ @"HostNames" : @{ @"LocalHostName" : @"finch-test" } } },
    };
    [plist writeToFile:path atomically:YES];
    SCPreferencesRef p = SCPreferencesCreate(NULL, CFSTR("finch-sysconfig-test"), (__bridge CFStringRef)path);
    printf("create %d type %d\n", p != NULL, p && CFGetTypeID(p) == SCPreferencesGetTypeID());
    NSArray *keys = CFBridgingRelease(SCPreferencesCopyKeyList(p));
    printf("keys %s\n", [[keys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","].UTF8String);
    NSString *current = (__bridge NSString *)SCPreferencesGetValue(p, kSCPrefCurrentSet);
    printf("current set %s\n", current.UTF8String);
    NSDictionary *sys = (__bridge NSDictionary *)SCPreferencesPathGetValue(p, CFSTR("/System/System"));
    printf("path value %s name %s\n", typeName(sys).UTF8String, [sys[@"ComputerName"] UTF8String]);
    NSDictionary *link = (__bridge NSDictionary *)SCPreferencesPathGetValue(p, CFSTR("/Sets/SET1/Network/Service/SVC1"));
    printf("linked value %s name %s\n", typeName(link).UTF8String, [link[@"UserDefinedName"] UTF8String]);
    NSString *target = (__bridge NSString *)SCPreferencesPathGetLink(p, CFSTR("/Sets/SET1/Network/Service/SVC1"));
    printf("link %s\n", target.UTF8String);
    printf("not a link %d\n", SCPreferencesPathGetLink(p, CFSTR("/System/System")) != NULL);
    printf("missing path %d error %d\n", SCPreferencesPathGetValue(p, CFSTR("/Nothing/Here")) != NULL, SCError());
    printf("missing key %d error %d\n", SCPreferencesGetValue(p, CFSTR("Nothing")) != NULL, SCError());
    NSData *sig = (__bridge NSData *)SCPreferencesGetSignature(p);
    printf("signature %s\n", typeName(sig).UTF8String);
    SCPreferencesSynchronize(p);
    printf("after synchronize %s\n", [(__bridge NSString *)SCPreferencesGetValue(p, kSCPrefCurrentSet) UTF8String]);
    printf("set value %d", SCPreferencesSetValue(p, CFSTR("FinchTest"), (__bridge CFPropertyListRef) @{ @"a" : @1 }));
    printf(" get %s", typeName((__bridge id)SCPreferencesGetValue(p, CFSTR("FinchTest"))).UTF8String);
    printf(" add existing %d error %d", SCPreferencesAddValue(p, CFSTR("FinchTest"), (__bridge CFPropertyListRef) @{}), SCError());
    printf(" remove %d", SCPreferencesRemoveValue(p, CFSTR("FinchTest")));
    printf(" remove again %d error %d\n", SCPreferencesRemoveValue(p, CFSTR("FinchTest")), SCError());
    printf("path set %d", SCPreferencesPathSetValue(p, CFSTR("/FinchPath/Sub"), (__bridge CFDictionaryRef) @{ @"x" : @"y" }));
    printf(" get %s", [((__bridge NSDictionary *)SCPreferencesPathGetValue(p, CFSTR("/FinchPath/Sub")))[@"x"] UTF8String]);
    printf(" remove %d\n", SCPreferencesPathRemoveValue(p, CFSTR("/FinchPath/Sub")));
    printf("callback %d\n", SCPreferencesSetCallback(p, NULL, NULL));
    dispatch_queue_t queue = dispatch_queue_create("prefs", NULL);
    printf("dispatch queue %d clear %d\n", SCPreferencesSetDispatchQueue(p, queue), SCPreferencesSetDispatchQueue(p, NULL));

    printf("== network configuration\n");
    SCNetworkSetRef set = SCNetworkSetCopyCurrent(p);
    printf("current set %d id %s name %s type %d\n", set != NULL, [(__bridge NSString *)SCNetworkSetGetSetID(set) UTF8String],
           [(__bridge NSString *)SCNetworkSetGetName(set) UTF8String], set && CFGetTypeID(set) == SCNetworkSetGetTypeID());
    NSArray *services = CFBridgingRelease(SCNetworkSetCopyServices(set));
    NSMutableArray *desc = [NSMutableArray array];
    for (id sv in services) {
        SCNetworkServiceRef svc = (__bridge SCNetworkServiceRef)sv;
        SCNetworkInterfaceRef i = SCNetworkServiceGetInterface(svc);
        [desc addObject:[NSString stringWithFormat:@"%@ '%@' enabled %d if %@ %@ '%@' type %d", SCNetworkServiceGetServiceID(svc),
                                                   SCNetworkServiceGetName(svc), SCNetworkServiceGetEnabled(svc),
                                                   SCNetworkInterfaceGetBSDName(i), SCNetworkInterfaceGetInterfaceType(i),
                                                   SCNetworkInterfaceGetLocalizedDisplayName(i),
                                                   CFGetTypeID(svc) == SCNetworkServiceGetTypeID()]];
    }
    [desc sortUsingSelector:@selector(compare:)];
    for (NSString *d in desc)
        printf("  %s\n", d.UTF8String);
    NSArray *allSets = CFBridgingRelease(SCNetworkSetCopyAll(p));
    printf("all sets %lu\n", (unsigned long)allSets.count);
    NSArray *allServices = CFBridgingRelease(SCNetworkServiceCopyAll(p));
    printf("all services %lu\n", (unsigned long)allServices.count);
    NSArray *order = CFBridgingRelease(SCNetworkSetGetServiceOrder(set) ? CFRetain(SCNetworkSetGetServiceOrder(set)) : NULL);
    printf("service order %s\n", [order componentsJoinedByString:@","].UTF8String);
    SCNetworkServiceRef byID = SCNetworkServiceCopy(p, CFSTR("SVC1"));
    printf("service by id %d\n", byID != NULL);
    SCNetworkProtocolRef ipv4 = byID ? SCNetworkServiceCopyProtocol(byID, kSCNetworkProtocolTypeIPv4) : NULL;
    printf("ipv4 protocol %d type %s method %s enabled %d\n", ipv4 != NULL, [(__bridge NSString *)SCNetworkProtocolGetProtocolType(ipv4) UTF8String],
           [((__bridge NSDictionary *)SCNetworkProtocolGetConfiguration(ipv4))[@"ConfigMethod"] UTF8String], ipv4 ? SCNetworkProtocolGetEnabled(ipv4) : 0);
    NSArray *protos = byID ? CFBridgingRelease(SCNetworkServiceCopyProtocols(byID)) : nil;
    NSMutableArray *ptypes = [NSMutableArray array];
    for (id pr in protos)
        [ptypes addObject:(__bridge NSString *)SCNetworkProtocolGetProtocolType((__bridge SCNetworkProtocolRef)pr)];
    [ptypes sortUsingSelector:@selector(compare:)];
    printf("protocols %s\n", [ptypes componentsJoinedByString:@","].UTF8String);
    if (ipv4) CFRelease(ipv4);
    if (byID) CFRelease(byID);
    if (set) CFRelease(set);
    CFRelease(p);
    unlink(path.fileSystemRepresentation);

    SCPreferencesRef none = SCPreferencesCreate(NULL, CFSTR("finch-sysconfig-test"), CFSTR("/nonexistent/finch/prefs.plist"));
    printf("missing file %d keys %lu current %d\n", none != NULL, (unsigned long)[CFBridgingRelease(SCPreferencesCopyKeyList(none)) count],
           none && SCNetworkSetCopyCurrent(none) != NULL);
    if (none) CFRelease(none);
}

static void
interfaces(void)
{
    printf("== interfaces\n");
    NSArray *all = CFBridgingRelease(SCNetworkInterfaceCopyAll());
    bool named = true, typed = true, loopback = false;
    for (id x in all) {
        SCNetworkInterfaceRef i = (__bridge SCNetworkInterfaceRef)x;
        named = named && SCNetworkInterfaceGetBSDName(i) != NULL;
        typed = typed && SCNetworkInterfaceGetInterfaceType(i) != NULL;
        loopback = loopback || [(__bridge NSString *)SCNetworkInterfaceGetBSDName(i) isEqual:@"lo0"];
        if (CFGetTypeID(i) != SCNetworkInterfaceGetTypeID())
            typed = false;
    }
    printf("all %s named %d typed %d loopback %d\n", typeName(all).UTF8String, named, typed, loopback);
    printf("ipv4 interface %s\n", [(__bridge NSString *)SCNetworkInterfaceGetInterfaceType(kSCNetworkInterfaceIPv4) UTF8String]);
}

int
main(void)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    Dl_info dl;
    dladdr((const void *)SCDynamicStoreCreate, &dl);
    printf("finch-sysconfig-test: SystemConfiguration from %s\n", dl.dli_fname);
    @autoreleasepool {
        constants();
        keys();
        errors();
        store();
        reachability();
        preferences();
        interfaces();
    }
    printf("== done\n");
    return 0;
}
