/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * NSPort and NSMachPort (docs/design/FOUNDATION.md), in CoreFoundation as
 * Apple's are, over CFMachPort. +[NSPort port] is a new Mach port with a
 * receive right and a send right. A message's components travel as Mach
 * descriptors: NSData as out-of-line memory, ports as port rights. On
 * receipt the delegate gets -handleMachMessage: if it has it, else
 * -handlePortMessage: with Foundation's NSPortMessage.
 */
#include "CFObjCClasses_Finch.h"
#include <CoreFoundation/CFMachPort.h>
#include <mach/mach.h>

typedef NSUInteger NSMachPortOptions;
enum { NSMachPortDeallocateNone = 0, NSMachPortDeallocateSendRight = 1 << 0, NSMachPortDeallocateReceiveRight = 1 << 1 };

@interface NSObject (FinchPortMessages)
- (void)handleMachMessage:(void *)msg;
- (void)handlePortMessage:(id)message;
- (CFRunLoopRef)getCFRunLoop;
- (id)initWithSendPort:(id)send receivePort:(id)receive components:(id)components;
- (void)setMsgid:(uint32_t)msgid;
- (CFTimeInterval)timeIntervalSinceNow;
+ (id)defaultCenter;
- (void)postNotificationName:(id)name object:(id)object;
@end

@interface NSPort ()
- (id)delegate;
- (void)setDelegate:(id)delegate;
- (void)scheduleInRunLoop:(id)runLoop forMode:(id)mode;
- (void)removeFromRunLoop:(id)runLoop forMode:(id)mode;
- (BOOL)sendBeforeDate:(id)limitDate msgid:(NSUInteger)msgID components:(id)components from:(NSPort *)receivePort reserved:(NSUInteger)headerSpaceReserved;
@end

@interface NSMachPort () {
    CFMachPortRef _port;
    CFRunLoopSourceRef _source;
    id _delegate;        /* not retained */
    NSMachPortOptions _options;
}
- (instancetype)initWithMachPort:(uint32_t)machPort options:(NSMachPortOptions)options;
@end

static void __attribute__((noreturn))
abstract(id self, SEL _cmd)
{
    char kind = object_isClass(self) ? '+' : '-';
    __CFFinchRaise(NSInvalidArgumentException, "*** %c[%s %s]: method only defined for abstract class.  Define %c[%s %s]!",
        kind, object_getClassName(self), sel_getName(_cmd), kind, object_getClassName(self), sel_getName(_cmd));
}

/* MARK: - NSPort */

@implementation NSPort

+ (instancetype)allocWithZone:(struct _NSZone *)zone
{
    if (self == [NSPort class]) return [NSMachPort allocWithZone:zone];
    return [super allocWithZone:zone];
}

+ (NSPort *)port { return [[[self alloc] init] autorelease]; }

- (void)invalidate { abstract(self, _cmd); }
- (BOOL)isValid { abstract(self, _cmd); }
- (id)delegate { abstract(self, _cmd); }
- (void)setDelegate:(id)delegate { abstract(self, _cmd); }
- (void)scheduleInRunLoop:(id)runLoop forMode:(id)mode { abstract(self, _cmd); }
- (void)removeFromRunLoop:(id)runLoop forMode:(id)mode { abstract(self, _cmd); }
- (NSUInteger)reservedSpaceLength { return 0; }

- (BOOL)sendBeforeDate:(id)limitDate components:(id)components from:(NSPort *)receivePort reserved:(NSUInteger)headerSpaceReserved
{
    return [self sendBeforeDate:limitDate msgid:0 components:components from:receivePort reserved:headerSpaceReserved];
}

- (BOOL)sendBeforeDate:(id)limitDate msgid:(NSUInteger)msgID components:(id)components from:(NSPort *)receivePort reserved:(NSUInteger)headerSpaceReserved
{
    abstract(self, _cmd);
}

- (id)copyWithZone:(struct _NSZone *)zone { return [self retain]; }

@end

/* MARK: - NSMachPort */

static CFMutableDictionaryRef ports;   /* mach_port_t -> NSMachPort, so one object per port */
static pthread_mutex_t ports_lock = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
} ComplexHeader;

/* A received message to Foundation's NSPortMessage: data and ports. */
static id
port_message(mach_msg_header_t *msg, NSMachPort *receiver)
{
    CFMutableArrayRef components = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (msg->msgh_bits & MACH_MSGH_BITS_COMPLEX) {
        ComplexHeader *h = (ComplexHeader *)msg;
        mach_msg_descriptor_t *d = (mach_msg_descriptor_t *)(h + 1);
        for (mach_msg_size_t i = 0; i < h->body.msgh_descriptor_count; i++) {
            if (d->type.type == MACH_MSG_OOL_DESCRIPTOR) {
                mach_msg_ool_descriptor_t *o = (mach_msg_ool_descriptor_t *)d;
                CFDataRef data = CFDataCreate(NULL, o->address, (CFIndex)o->size);
                CFArrayAppendValue(components, data);
                CFRelease(data);
                vm_deallocate(mach_task_self(), (vm_address_t)o->address, o->size);
                d = (mach_msg_descriptor_t *)(o + 1);
            } else if (d->type.type == MACH_MSG_PORT_DESCRIPTOR) {
                mach_msg_port_descriptor_t *p = (mach_msg_port_descriptor_t *)d;
                NSMachPort *port = [[NSMachPort alloc] initWithMachPort:p->name options:NSMachPortDeallocateSendRight];
                CFArrayAppendValue(components, port);
                [port release];
                d = (mach_msg_descriptor_t *)(p + 1);
            } else {
                break;
            }
        }
    }
    id sendPort = nil;
    if (MACH_MSGH_BITS_REMOTE(msg->msgh_bits) && msg->msgh_remote_port)
        sendPort = [[[NSMachPort alloc] initWithMachPort:msg->msgh_remote_port options:NSMachPortDeallocateSendRight] autorelease];
    id m = [[objc_getClass("NSPortMessage") alloc] initWithSendPort:sendPort receivePort:receiver components:(id)components];
    [m setMsgid:(uint32_t)msg->msgh_id];
    CFRelease(components);
    return [m autorelease];
}

static void
received(CFMachPortRef port, void *msg, CFIndex size, void *info)
{
    NSMachPort *self = info;
    id d = [self delegate];
    if ([d respondsToSelector:@selector(handleMachMessage:)]) [d handleMachMessage:msg];
    else if ([d respondsToSelector:@selector(handlePortMessage:)]) [d handlePortMessage:port_message(msg, self)];
}

@implementation NSMachPort

+ (NSPort *)portWithMachPort:(uint32_t)machPort { return [[[self alloc] initWithMachPort:machPort] autorelease]; }
+ (NSPort *)portWithMachPort:(uint32_t)machPort options:(NSMachPortOptions)options
{
    return [[[self alloc] initWithMachPort:machPort options:options] autorelease];
}

- (instancetype)init
{
    mach_port_t p = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p) != KERN_SUCCESS ||
        mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        [self release];
        return nil;
    }
    return [self initWithMachPort:p options:NSMachPortDeallocateSendRight | NSMachPortDeallocateReceiveRight];
}

- (instancetype)initWithMachPort:(uint32_t)machPort { return [self initWithMachPort:machPort options:NSMachPortDeallocateSendRight]; }

/* One object per port: a port already wrapped gives that object back. */
- (instancetype)initWithMachPort:(uint32_t)machPort options:(NSMachPortOptions)options
{
    pthread_mutex_lock(&ports_lock);
    NSMachPort *existing = ports ? (id)CFDictionaryGetValue(ports, (const void *)(uintptr_t)machPort) : nil;
    if (existing) {
        [existing retain];
        pthread_mutex_unlock(&ports_lock);
        [self release];
        return existing;
    }
    if ((self = [super init])) {
        CFMachPortContext ctx = { 0, self, NULL, NULL, NULL };
        _port = CFMachPortCreateWithPort(NULL, machPort, received, &ctx, NULL);
        _options = options;
        if (!ports) ports = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
        CFDictionarySetValue(ports, (const void *)(uintptr_t)machPort, self);
    }
    pthread_mutex_unlock(&ports_lock);
    return self;
}

- (void)dealloc
{
    pthread_mutex_lock(&ports_lock);
    mach_port_t p = [self machPort];
    if (ports && CFDictionaryGetValue(ports, (const void *)(uintptr_t)p) == self) CFDictionaryRemoveValue(ports, (const void *)(uintptr_t)p);
    pthread_mutex_unlock(&ports_lock);
    if (_source) {
        CFRunLoopSourceInvalidate(_source);
        CFRelease(_source);
    }
    if (_port) {
        CFMachPortInvalidate(_port);
        CFRelease(_port);
    }
    if (_options & NSMachPortDeallocateReceiveRight) mach_port_mod_refs(mach_task_self(), p, MACH_PORT_RIGHT_RECEIVE, -1);
    if (_options & NSMachPortDeallocateSendRight) mach_port_deallocate(mach_task_self(), p);
    [super dealloc];
}

- (uint32_t)machPort { return _port ? CFMachPortGetPort(_port) : MACH_PORT_NULL; }
- (BOOL)isValid { return _port && CFMachPortIsValid(_port); }
- (id)delegate { return _delegate; }
- (void)setDelegate:(id)delegate { _delegate = delegate; }

- (void)invalidate
{
    if (![self isValid]) return;
    CFMachPortInvalidate(_port);
    [[objc_getClass("NSNotificationCenter") defaultCenter] postNotificationName:(id)CFSTR("NSPortDidBecomeInvalidNotification") object:self];
}

- (void)scheduleInRunLoop:(id)runLoop forMode:(id)mode
{
    if (!_source) _source = CFMachPortCreateRunLoopSource(NULL, _port, 0);
    CFRunLoopAddSource([runLoop getCFRunLoop], _source, (CFStringRef)mode);
}

- (void)removeFromRunLoop:(id)runLoop forMode:(id)mode
{
    if (_source) CFRunLoopRemoveSource([runLoop getCFRunLoop], _source, (CFStringRef)mode);
}

- (NSUInteger)hash { return [self machPort]; }
- (BOOL)isEqual:(id)object { return object == self || ([object isKindOfClass:[NSMachPort class]] && [object machPort] == [self machPort]); }

/* Components as descriptors: NSData out of line, NSMachPort as a copied
 * send right. The reply port is the receive port's send right. */
- (BOOL)sendBeforeDate:(id)limitDate msgid:(NSUInteger)msgID components:(id)components from:(NSPort *)receivePort reserved:(NSUInteger)headerSpaceReserved
{
    CFIndex n = components ? CFArrayGetCount((CFArrayRef)components) : 0;
    size_t size = sizeof(ComplexHeader) + (size_t)n * sizeof(mach_msg_ool_descriptor_t) + 64;
    uint8_t *buf = calloc(1, size);
    ComplexHeader *h = (ComplexHeader *)buf;
    uint8_t *at = buf + sizeof(ComplexHeader);
    mach_msg_size_t count = 0;
    for (CFIndex i = 0; i < n; i++) {
        id c = (id)CFArrayGetValueAtIndex((CFArrayRef)components, i);
        if ([c isKindOfClass:[NSMachPort class]]) {
            mach_msg_port_descriptor_t *p = (mach_msg_port_descriptor_t *)at;
            p->name = [c machPort];
            p->disposition = MACH_MSG_TYPE_COPY_SEND;
            p->type = MACH_MSG_PORT_DESCRIPTOR;
            at += sizeof(*p);
        } else if (CFGetTypeID((CFTypeRef)c) == CFDataGetTypeID()) {
            mach_msg_ool_descriptor_t *o = (mach_msg_ool_descriptor_t *)at;
            o->address = (void *)CFDataGetBytePtr((CFDataRef)c);
            o->size = (mach_msg_size_t)CFDataGetLength((CFDataRef)c);
            o->deallocate = false;
            o->copy = MACH_MSG_VIRTUAL_COPY;
            o->type = MACH_MSG_OOL_DESCRIPTOR;
            at += sizeof(*o);
        } else {
            continue;
        }
        count++;
    }
    mach_port_t reply = [receivePort isKindOfClass:[NSMachPort class]] ? [(NSMachPort *)receivePort machPort] : MACH_PORT_NULL;
    h->header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, reply ? MACH_MSG_TYPE_MAKE_SEND : 0) | (count ? MACH_MSGH_BITS_COMPLEX : 0);
    h->header.msgh_size = (mach_msg_size_t)(at - buf);
    h->header.msgh_remote_port = [self machPort];
    h->header.msgh_local_port = reply;
    h->header.msgh_id = (mach_msg_id_t)msgID;
    h->body.msgh_descriptor_count = count;
    double wait = limitDate ? [limitDate timeIntervalSinceNow] : 0;
    mach_msg_timeout_t timeout = wait > 0 ? (mach_msg_timeout_t)(wait * 1000) : 0;
    kern_return_t kr = mach_msg(&h->header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, h->header.msgh_size, 0, MACH_PORT_NULL, timeout, MACH_PORT_NULL);
    free(buf);
    if (kr == MACH_SEND_TIMED_OUT) __CFFinchRaise((NSString *)CFSTR("NSPortTimeoutException"), "[NSMachPort sendBeforeDate:] timed out");
    return kr == KERN_SUCCESS;
}

@end
