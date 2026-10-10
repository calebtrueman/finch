/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * NSNetService and NSNetServiceBrowser: Bonjour service discovery, publishing and
 * resolution over the DNS Service Discovery client API (dns_sd.h), each operation's
 * socket watched on the run loops the object is scheduled in (the current run loop's
 * default mode unless told otherwise), as Apple's are. Where no mDNS responder runs,
 * operations fail and the delegate hears why (didNotSearch:, didNotResolve:,
 * didNotPublish:) with the NSNetServicesError the responder's error maps to.
 */
#import <Foundation/Foundation.h>
#include <arpa/inet.h>
#include <dns_sd.h>
#include <netinet/in.h>
#include <string.h>

NSString *const NSNetServicesErrorCode = @"NSNetServicesErrorCode";
NSErrorDomain const NSNetServicesErrorDomain = @"NSNetServicesErrorDomain";

static NSNetServicesError
ns_error(DNSServiceErrorType e)
{
    switch (e) {
    case kDNSServiceErr_NameConflict: return NSNetServicesCollisionError;
    case kDNSServiceErr_NoSuchName:
    case kDNSServiceErr_NoSuchRecord: return NSNetServicesNotFoundError;
    case kDNSServiceErr_BadParam: return NSNetServicesBadArgumentError;
    case kDNSServiceErr_Invalid: return NSNetServicesInvalidError;
    case kDNSServiceErr_Timeout: return NSNetServicesTimeoutError;
    default: return NSNetServicesUnknownError;
    }
}

static NSDictionary *
error_dict(NSNetServicesError e)
{
    return @{NSNetServicesErrorCode : @(e), NSNetServicesErrorDomain : @(10)};
}

/* One DNS-SD operation, its socket on the scheduled run loops. */
@interface _NSDNSOperation : NSObject {
@public
    DNSServiceRef ref;
    CFFileDescriptorRef fd;
    CFRunLoopSourceRef source;
    NSMutableArray *schedules; /* [run loop, mode] pairs */
}
- (instancetype)initWithRef:(DNSServiceRef)r schedules:(NSArray *)s;
- (void)cancel;
@end

static void
operation_readable(CFFileDescriptorRef f, CFOptionFlags flags, void *info)
{
    _NSDNSOperation *op = (_NSDNSOperation *)info;
    [op retain];
    if (op->ref && DNSServiceProcessResult(op->ref) != kDNSServiceErr_NoError) {
        [op cancel];
    } else if (op->fd) {
        CFFileDescriptorEnableCallBacks(op->fd, kCFFileDescriptorReadCallBack);
    }
    [op release];
}

@implementation _NSDNSOperation

- (instancetype)initWithRef:(DNSServiceRef)r schedules:(NSArray *)s
{
    if ((self = [super init])) {
        ref = r;
        schedules = [s mutableCopy];
        CFFileDescriptorContext ctx = {0, self, NULL, NULL, NULL};
        fd = CFFileDescriptorCreate(NULL, DNSServiceRefSockFD(ref), false, operation_readable, &ctx);
        CFFileDescriptorEnableCallBacks(fd, kCFFileDescriptorReadCallBack);
        source = CFFileDescriptorCreateRunLoopSource(NULL, fd, 0);
        for (NSArray *pair in schedules)
            CFRunLoopAddSource([[pair objectAtIndex:0] getCFRunLoop], source, (CFStringRef)[pair objectAtIndex:1]);
    }
    return self;
}

- (void)cancel
{
    if (source) {
        CFRunLoopSourceInvalidate(source);
        CFRelease(source);
        source = NULL;
    }
    if (fd) {
        CFFileDescriptorInvalidate(fd);
        CFRelease(fd);
        fd = NULL;
    }
    if (ref) {
        DNSServiceRefDeallocate(ref);
        ref = NULL;
    }
}

- (void)dealloc
{
    [self cancel];
    [schedules release];
    [super dealloc];
}

@end

static NSMutableArray *
default_schedules(void)
{
    return [NSMutableArray arrayWithObject:@[[NSRunLoop currentRunLoop], NSDefaultRunLoopMode]];
}

static void
schedule_add(NSMutableArray *schedules, _NSDNSOperation *op, NSRunLoop *loop, NSRunLoopMode mode)
{
    [schedules addObject:@[loop, mode]];
    if (op && op->source)
        CFRunLoopAddSource([loop getCFRunLoop], op->source, (CFStringRef)mode);
}

static void
schedule_remove(NSMutableArray *schedules, _NSDNSOperation *op, NSRunLoop *loop, NSRunLoopMode mode)
{
    for (NSUInteger i = 0; i < [schedules count]; i++) {
        NSArray *pair = [schedules objectAtIndex:i];
        if ([pair objectAtIndex:0] == loop && [[pair objectAtIndex:1] isEqualToString:mode]) {
            [schedules removeObjectAtIndex:i];
            break;
        }
    }
    if (op && op->source)
        CFRunLoopRemoveSource([loop getCFRunLoop], op->source, (CFStringRef)mode);
}

#pragma mark - NSNetService

/* What _netService points at. */
@interface _NSNetServiceState : NSObject {
@public
    NSString *domain, *type, *name, *hostName;
    int port;
    NSMutableArray *addresses;
    NSData *txt;
    NSMutableArray *schedules;
    _NSDNSOperation *resolve, *publish, *monitor, *address;
    NSTimer *timeout;
    BOOL published;
}
@end

@implementation _NSNetServiceState
- (void)dealloc
{
    [resolve cancel];
    [publish cancel];
    [monitor cancel];
    [address cancel];
    [resolve release];
    [publish release];
    [monitor release];
    [address release];
    [timeout invalidate];
    [domain release];
    [type release];
    [name release];
    [hostName release];
    [addresses release];
    [txt release];
    [schedules release];
    [super dealloc];
}
@end

#define STATE ((_NSNetServiceState *)_netService)

@implementation NSNetService

- (instancetype)initWithDomain:(NSString *)domain type:(NSString *)type name:(NSString *)name port:(int)port
{
    if ((self = [super init])) {
        _NSNetServiceState *s = [[_NSNetServiceState alloc] init];
        s->domain = [domain copy];
        s->type = [type copy];
        s->name = [name copy];
        s->port = port;
        s->schedules = [default_schedules() retain];
        _netService = s;
    }
    return self;
}

- (instancetype)initWithDomain:(NSString *)domain type:(NSString *)type name:(NSString *)name
{
    return [self initWithDomain:domain type:type name:name port:-1];
}

- (instancetype)init
{
    return [self initWithDomain:@"" type:@"" name:@"" port:-1];
}

- (void)dealloc
{
    [_netService release];
    [super dealloc];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p> %@.%@%@ -1", [self class], self, STATE->domain, STATE->type, STATE->name];
}

- (id<NSNetServiceDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSNetServiceDelegate>)delegate { _delegate = delegate; }
- (BOOL)includesPeerToPeer { return NO; }
- (void)setIncludesPeerToPeer:(BOOL)includesPeerToPeer {}
- (NSString *)name { return STATE->name; }
- (NSString *)type { return STATE->type; }
- (NSString *)domain { return STATE->domain; }
- (NSString *)hostName { return STATE->hostName; }
- (NSArray<NSData *> *)addresses { return STATE->addresses ? [[STATE->addresses copy] autorelease] : nil; }
- (NSInteger)port { return STATE->port; }

- (void)scheduleInRunLoop:(NSRunLoop *)aRunLoop forMode:(NSRunLoopMode)mode
{
    schedule_add(STATE->schedules, STATE->resolve ?: STATE->publish, aRunLoop, mode);
}

- (void)removeFromRunLoop:(NSRunLoop *)aRunLoop forMode:(NSRunLoopMode)mode
{
    schedule_remove(STATE->schedules, STATE->resolve ?: STATE->publish, aRunLoop, mode);
}

- (void)_tell:(SEL)sel with:(id)arg
{
    if ([_delegate respondsToSelector:sel])
        [_delegate performSelector:sel withObject:self withObject:arg];
}

- (void)_tell:(SEL)sel
{
    if ([_delegate respondsToSelector:sel])
        [_delegate performSelector:sel withObject:self];
}

/* --- publishing --- */

static void
register_reply(DNSServiceRef ref, DNSServiceFlags flags, DNSServiceErrorType error, const char *name,
               const char *regtype, const char *domain, void *context)
{
    NSNetService *svc = (NSNetService *)context;
    _NSNetServiceState *s = (_NSNetServiceState *)svc->_netService;
    if (error != kDNSServiceErr_NoError) {
        [s->publish cancel];
        [svc _tell:@selector(netService:didNotPublish:) with:error_dict(ns_error(error))];
        return;
    }
    if (name) {
        [s->name autorelease];
        s->name = [[NSString alloc] initWithUTF8String:name];
    }
    if (domain) {
        [s->domain autorelease];
        s->domain = [[NSString alloc] initWithUTF8String:domain];
    }
    s->published = YES;
    [svc _tell:@selector(netServiceDidPublish:)];
}

- (void)publishWithOptions:(NSNetServiceOptions)options
{
    [self stop];
    _NSNetServiceState *s = STATE;
    if (s->port < 0 || ![s->type length]) {
        [self _tell:@selector(netService:didNotPublish:) with:error_dict(NSNetServicesBadArgumentError)];
        return;
    }
    [self _tell:@selector(netServiceWillPublish:)];
    DNSServiceRef ref = NULL;
    DNSServiceFlags flags = (options & NSNetServiceNoAutoRename) ? kDNSServiceFlagsNoAutoRename : 0;
    DNSServiceErrorType e = DNSServiceRegister(&ref, flags, 0, [s->name length] ? [s->name UTF8String] : NULL,
                                               [s->type UTF8String], [s->domain length] ? [s->domain UTF8String] : NULL,
                                               NULL, htons((uint16_t)s->port), (uint16_t)[s->txt length], [s->txt bytes],
                                               register_reply, self);
    if (e != kDNSServiceErr_NoError) {
        [self _tell:@selector(netService:didNotPublish:) with:error_dict(ns_error(e))];
        return;
    }
    s->publish = [[_NSDNSOperation alloc] initWithRef:ref schedules:s->schedules];
}

- (void)publish { [self publishWithOptions:[STATE->name length] ? NSNetServiceNoAutoRename : 0]; }

/* --- resolving --- */

static void
address_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType error,
              const char *hostname, const struct sockaddr *address, uint32_t ttl, void *context)
{
    NSNetService *svc = (NSNetService *)context;
    _NSNetServiceState *s = (_NSNetServiceState *)svc->_netService;
    if (error == kDNSServiceErr_NoError && address && (flags & kDNSServiceFlagsAdd)) {
        size_t len = address->sa_family == AF_INET6 ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in);
        NSMutableData *d = [NSMutableData dataWithBytes:address length:len];
        if (address->sa_family == AF_INET6)
            ((struct sockaddr_in6 *)[d mutableBytes])->sin6_port = htons((uint16_t)s->port);
        else
            ((struct sockaddr_in *)[d mutableBytes])->sin_port = htons((uint16_t)s->port);
        if (!s->addresses)
            s->addresses = [[NSMutableArray alloc] init];
        if (![s->addresses containsObject:d])
            [s->addresses addObject:d];
    }
    if (!(flags & kDNSServiceFlagsMoreComing)) {
        [s->timeout invalidate];
        s->timeout = nil;
        [svc _tell:@selector(netServiceDidResolveAddress:)];
    }
}

static void
resolve_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType error,
              const char *fullname, const char *hosttarget, uint16_t port, uint16_t txtLen,
              const unsigned char *txtRecord, void *context)
{
    NSNetService *svc = (NSNetService *)context;
    _NSNetServiceState *s = (_NSNetServiceState *)svc->_netService;
    if (error != kDNSServiceErr_NoError) {
        [s->timeout invalidate];
        s->timeout = nil;
        [svc _tell:@selector(netService:didNotResolve:) with:error_dict(ns_error(error))];
        return;
    }
    [s->hostName autorelease];
    s->hostName = [[NSString alloc] initWithUTF8String:hosttarget];
    s->port = ntohs(port);
    [s->txt autorelease];
    s->txt = [[NSData alloc] initWithBytes:txtRecord length:txtLen];
    DNSServiceRef aref = NULL;
    if (DNSServiceGetAddrInfo(&aref, 0, interfaceIndex, kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6, hosttarget,
                              address_reply, svc) == kDNSServiceErr_NoError) {
        [s->address cancel];
        [s->address release];
        s->address = [[_NSDNSOperation alloc] initWithRef:aref schedules:s->schedules];
    }
}

- (void)_resolveTimedOut:(NSTimer *)timer
{
    STATE->timeout = nil;
    [self stop];
    [self _tell:@selector(netService:didNotResolve:) with:error_dict(NSNetServicesTimeoutError)];
}

- (void)resolveWithTimeout:(NSTimeInterval)timeout
{
    [self stop];
    _NSNetServiceState *s = STATE;
    [self _tell:@selector(netServiceWillResolve:)];
    DNSServiceRef ref = NULL;
    DNSServiceErrorType e = DNSServiceResolve(&ref, 0, 0, [s->name UTF8String], [s->type UTF8String],
                                              [s->domain length] ? [s->domain UTF8String] : "local.", resolve_reply, self);
    if (e != kDNSServiceErr_NoError) {
        [self _tell:@selector(netService:didNotResolve:) with:error_dict(ns_error(e))];
        return;
    }
    s->resolve = [[_NSDNSOperation alloc] initWithRef:ref schedules:s->schedules];
    if (timeout > 0)
        s->timeout = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(_resolveTimedOut:)
                                                    userInfo:nil repeats:NO];
}

- (void)resolve { [self resolveWithTimeout:5]; }

- (void)stop
{
    _NSNetServiceState *s = STATE;
    BOOL was = s->resolve || s->publish;
    [s->timeout invalidate];
    s->timeout = nil;
    _NSDNSOperation **ops[] = {&s->resolve, &s->publish, &s->address};
    for (size_t i = 0; i < sizeof ops / sizeof *ops; i++) {
        [*ops[i] cancel];
        [*ops[i] release];
        *ops[i] = nil;
    }
    s->published = NO;
    if (was)
        [self _tell:@selector(netServiceDidStop:)];
}

/* --- TXT records --- */

+ (NSDictionary<NSString *, NSData *> *)dictionaryFromTXTRecordData:(NSData *)txtData
{
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    const uint8_t *p = [txtData bytes], *end = p + [txtData length];
    while (p < end) {
        uint8_t len = *p++;
        if (p + len > end)
            break;
        const uint8_t *eq = memchr(p, '=', len);
        NSString *key = [[[NSString alloc] initWithBytes:p length:(NSUInteger)(eq ? eq - p : len)
                                                encoding:NSUTF8StringEncoding] autorelease];
        if (key && ![d objectForKey:key])
            [d setObject:eq ? (id)[NSData dataWithBytes:eq + 1 length:(NSUInteger)(p + len - eq - 1)] : (id)[NSNull null]
                  forKey:key];
        p += len;
    }
    return d;
}

+ (NSData *)dataFromTXTRecordDictionary:(NSDictionary<NSString *, NSData *> *)txtDictionary
{
    NSMutableData *out = [NSMutableData data];
    for (NSString *key in txtDictionary) {
        id v = [txtDictionary objectForKey:key];
        NSData *value = [v isKindOfClass:[NSData class]] ? v : [[v description] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *k = [key dataUsingEncoding:NSUTF8StringEncoding];
        NSUInteger len = [k length] + 1 + [value length];
        if (len > 255)
            return nil;
        uint8_t b = (uint8_t)len;
        [out appendBytes:&b length:1];
        [out appendData:k];
        [out appendBytes:"=" length:1];
        [out appendData:value];
    }
    return out;
}

- (BOOL)setTXTRecordData:(NSData *)recordData
{
    [STATE->txt autorelease];
    STATE->txt = [recordData copy];
    if (STATE->publish && STATE->publish->ref)
        return DNSServiceUpdateRecord(STATE->publish->ref, NULL, 0, (uint16_t)[recordData length], [recordData bytes], 0) ==
               kDNSServiceErr_NoError;
    return YES;
}

- (NSData *)TXTRecordData { return STATE->txt; }

static void
txt_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType error,
          const char *fullname, uint16_t rrtype, uint16_t rrclass, uint16_t rdlen, const void *rdata, uint32_t ttl,
          void *context)
{
    NSNetService *svc = (NSNetService *)context;
    _NSNetServiceState *s = (_NSNetServiceState *)svc->_netService;
    if (error != kDNSServiceErr_NoError || !(flags & kDNSServiceFlagsAdd))
        return;
    [s->txt autorelease];
    s->txt = [[NSData alloc] initWithBytes:rdata length:rdlen];
    if ([svc->_delegate respondsToSelector:@selector(netService:didUpdateTXTRecordData:)])
        [svc->_delegate netService:svc didUpdateTXTRecordData:s->txt];
}

- (void)startMonitoring
{
    _NSNetServiceState *s = STATE;
    if (s->monitor)
        return;
    char full[kDNSServiceMaxDomainName];
    if (DNSServiceConstructFullName(full, [s->name UTF8String], [s->type UTF8String],
                                    [s->domain length] ? [s->domain UTF8String] : "local.") != kDNSServiceErr_NoError)
        return;
    DNSServiceRef ref = NULL;
    if (DNSServiceQueryRecord(&ref, kDNSServiceFlagsLongLivedQuery, 0, full, kDNSServiceType_TXT, kDNSServiceClass_IN,
                              txt_reply, self) == kDNSServiceErr_NoError)
        s->monitor = [[_NSDNSOperation alloc] initWithRef:ref schedules:s->schedules];
}

- (void)stopMonitoring
{
    [STATE->monitor cancel];
    [STATE->monitor release];
    STATE->monitor = nil;
}

- (BOOL)getInputStream:(NSInputStream **)inputStream outputStream:(NSOutputStream **)outputStream
{
    NSString *host = STATE->hostName;
    if (!host || STATE->port <= 0)
        return NO;
    [NSStream getStreamsToHostWithName:host port:STATE->port inputStream:inputStream outputStream:outputStream];
    return (!inputStream || *inputStream) && (!outputStream || *outputStream);
}

@end

#undef STATE

#pragma mark - NSNetServiceBrowser

@interface _NSNetServiceBrowserState : NSObject {
@public
    NSMutableArray *schedules;
    _NSDNSOperation *op;
}
@end

@implementation _NSNetServiceBrowserState
- (void)dealloc
{
    [op cancel];
    [op release];
    [schedules release];
    [super dealloc];
}
@end

#define BSTATE ((_NSNetServiceBrowserState *)_netServiceBrowser)

@implementation NSNetServiceBrowser

- (instancetype)init
{
    if ((self = [super init])) {
        _NSNetServiceBrowserState *s = [[_NSNetServiceBrowserState alloc] init];
        s->schedules = [default_schedules() retain];
        _netServiceBrowser = s;
    }
    return self;
}

- (void)dealloc
{
    [_netServiceBrowser release];
    [super dealloc];
}

- (id<NSNetServiceBrowserDelegate>)delegate { return _delegate; }
- (void)setDelegate:(id<NSNetServiceBrowserDelegate>)delegate { _delegate = delegate; }
- (BOOL)includesPeerToPeer { return NO; }
- (void)setIncludesPeerToPeer:(BOOL)includesPeerToPeer {}

- (void)scheduleInRunLoop:(NSRunLoop *)aRunLoop forMode:(NSRunLoopMode)mode
{
    schedule_add(BSTATE->schedules, BSTATE->op, aRunLoop, mode);
}

- (void)removeFromRunLoop:(NSRunLoop *)aRunLoop forMode:(NSRunLoopMode)mode
{
    schedule_remove(BSTATE->schedules, BSTATE->op, aRunLoop, mode);
}

- (void)_failed:(DNSServiceErrorType)e
{
    if ([_delegate respondsToSelector:@selector(netServiceBrowser:didNotSearch:)])
        [_delegate netServiceBrowser:self didNotSearch:error_dict(ns_error(e))];
}

static void
browse_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType error,
             const char *serviceName, const char *regtype, const char *replyDomain, void *context)
{
    NSNetServiceBrowser *b = (NSNetServiceBrowser *)context;
    if (error != kDNSServiceErr_NoError) {
        [b stop];
        [b _failed:error];
        return;
    }
    NSNetService *svc = [[[NSNetService alloc] initWithDomain:@(replyDomain) type:@(regtype) name:@(serviceName)] autorelease];
    BOOL more = (flags & kDNSServiceFlagsMoreComing) != 0;
    id d = b->_delegate;
    if (flags & kDNSServiceFlagsAdd) {
        if ([d respondsToSelector:@selector(netServiceBrowser:didFindService:moreComing:)])
            [d netServiceBrowser:b didFindService:svc moreComing:more];
    } else if ([d respondsToSelector:@selector(netServiceBrowser:didRemoveService:moreComing:)]) {
        [d netServiceBrowser:b didRemoveService:svc moreComing:more];
    }
}

static void
domain_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interfaceIndex, DNSServiceErrorType error,
             const char *replyDomain, void *context)
{
    NSNetServiceBrowser *b = (NSNetServiceBrowser *)context;
    if (error != kDNSServiceErr_NoError) {
        [b stop];
        [b _failed:error];
        return;
    }
    BOOL more = (flags & kDNSServiceFlagsMoreComing) != 0;
    id d = b->_delegate;
    if (flags & kDNSServiceFlagsAdd) {
        if ([d respondsToSelector:@selector(netServiceBrowser:didFindDomain:moreComing:)])
            [d netServiceBrowser:b didFindDomain:@(replyDomain) moreComing:more];
    } else if ([d respondsToSelector:@selector(netServiceBrowser:didRemoveDomain:moreComing:)]) {
        [d netServiceBrowser:b didRemoveDomain:@(replyDomain) moreComing:more];
    }
}

- (void)_start:(DNSServiceRef)ref error:(DNSServiceErrorType)e
{
    if ([_delegate respondsToSelector:@selector(netServiceBrowserWillSearch:)])
        [_delegate netServiceBrowserWillSearch:self];
    if (e != kDNSServiceErr_NoError) {
        [self _failed:e];
        return;
    }
    BSTATE->op = [[_NSDNSOperation alloc] initWithRef:ref schedules:BSTATE->schedules];
}

- (void)searchForBrowsableDomains
{
    [self stop];
    DNSServiceRef ref = NULL;
    DNSServiceErrorType e = DNSServiceEnumerateDomains(&ref, kDNSServiceFlagsBrowseDomains, 0, domain_reply, self);
    [self _start:ref error:e];
}

- (void)searchForRegistrationDomains
{
    [self stop];
    DNSServiceRef ref = NULL;
    DNSServiceErrorType e = DNSServiceEnumerateDomains(&ref, kDNSServiceFlagsRegistrationDomains, 0, domain_reply, self);
    [self _start:ref error:e];
}

- (void)searchForServicesOfType:(NSString *)type inDomain:(NSString *)domainString
{
    [self stop];
    DNSServiceRef ref = NULL;
    DNSServiceErrorType e = DNSServiceBrowse(&ref, 0, 0, [type UTF8String],
                                             [domainString length] ? [domainString UTF8String] : NULL, browse_reply, self);
    [self _start:ref error:e];
}

- (void)stop
{
    if (!BSTATE->op)
        return;
    [BSTATE->op cancel];
    [BSTATE->op release];
    BSTATE->op = nil;
    if ([_delegate respondsToSelector:@selector(netServiceBrowserDidStopSearch:)])
        [_delegate netServiceBrowserDidStopSearch:self];
}

@end
