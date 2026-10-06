/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * XPC object classes. Built without ARC: lifetime is managed by libdispatch's
 * os_object retain/release (OS_object), as for dispatch objects.
 */

#import <objc/runtime.h>
#import <os/object.h>
#import <os/object_private.h>
#include <string.h>
#include <unistd.h>

#include "internal.h"

extern const struct _xpc_type_s _xpc_type_pipe;
void _xpc_pipe_dispose(xpc_object_t obj);
void _xpc_connection_dispose(xpc_object_t obj);
void _xpc_bundle_dispose(xpc_object_t obj);
void _xpc_compat_dispose(xpc_object_t obj);
extern const struct _xpc_type_s _xpc_type_bundle;

@interface OS_xpc_object : OS_object <OS_xpc_object>
@end

@implementation OS_xpc_object

- (void)dealloc
{
	_xpc_object_dispose(self);
	[super dealloc];
}

@end

/* One subclass per type. Apple's classes carry no extra methods we rely on. */
#define XPC_CLASS(name) \
	@interface OS_xpc_##name : OS_xpc_object \
	@end \
	@implementation OS_xpc_##name \
	@end

XPC_CLASS(null)
XPC_CLASS(bool)
XPC_CLASS(int64)
XPC_CLASS(uint64)
XPC_CLASS(double)
XPC_CLASS(date)
XPC_CLASS(data)
XPC_CLASS(string)
XPC_CLASS(uuid)
XPC_CLASS(fd)
XPC_CLASS(array)
XPC_CLASS(dictionary)
XPC_CLASS(error)
XPC_CLASS(mach_send)
XPC_CLASS(mach_recv)
XPC_CLASS(endpoint)
XPC_CLASS(pipe)
XPC_CLASS(connection)
XPC_CLASS(bundle)
XPC_CLASS(activity)
XPC_CLASS(pointer)
XPC_CLASS(rich_error)
XPC_CLASS(shmem)
XPC_CLASS(mach_send_once)
XPC_CLASS(session)
XPC_CLASS(listener)
XPC_CLASS(peer_requirement)
XPC_CLASS(transaction)
XPC_CLASS(file_transfer)
XPC_CLASS(serializer)
XPC_CLASS(service)
XPC_CLASS(service_instance)

/*
 * The exported type symbols are the classes themselves (as in Apple's
 * libxpc, where _xpc_type_dictionary and OBJC_CLASS_$_OS_xpc_dictionary share
 * an address).
 */
#define XPC_TYPE_ALIAS(name) \
	__asm__(".globl __xpc_type_" #name "\n" \
	        ".set __xpc_type_" #name ", _OBJC_CLASS_$_OS_xpc_" #name);

XPC_TYPE_ALIAS(null)
XPC_TYPE_ALIAS(bool)
XPC_TYPE_ALIAS(int64)
XPC_TYPE_ALIAS(uint64)
XPC_TYPE_ALIAS(double)
XPC_TYPE_ALIAS(date)
XPC_TYPE_ALIAS(data)
XPC_TYPE_ALIAS(string)
XPC_TYPE_ALIAS(uuid)
XPC_TYPE_ALIAS(fd)
XPC_TYPE_ALIAS(array)
XPC_TYPE_ALIAS(dictionary)
XPC_TYPE_ALIAS(error)
XPC_TYPE_ALIAS(mach_send)
XPC_TYPE_ALIAS(mach_recv)
XPC_TYPE_ALIAS(endpoint)
XPC_TYPE_ALIAS(pipe)
XPC_TYPE_ALIAS(connection)
XPC_TYPE_ALIAS(bundle)
XPC_TYPE_ALIAS(activity)
XPC_TYPE_ALIAS(pointer)
XPC_TYPE_ALIAS(rich_error)
XPC_TYPE_ALIAS(shmem)
XPC_TYPE_ALIAS(mach_send_once)
XPC_TYPE_ALIAS(session)
XPC_TYPE_ALIAS(listener)
XPC_TYPE_ALIAS(peer_requirement)
XPC_TYPE_ALIAS(transaction)
XPC_TYPE_ALIAS(file_transfer)
XPC_TYPE_ALIAS(serializer)
XPC_TYPE_ALIAS(service)
XPC_TYPE_ALIAS(service_instance)

xpc_object_t
_xpc_object_alloc(xpc_type_t type, size_t size)
{
	return (xpc_object_t)_os_object_alloc_realized((const void *)type, size);
}

void
_xpc_object_dispose(xpc_object_t obj)
{
	xpc_type_t type = xpc_get_type(obj);

	if (type == XPC_TYPE_DICTIONARY || type == XPC_TYPE_ERROR) {
		_xpc_dictionary_dispose((struct _xpc_dictionary_s *)obj);
	} else if (type == XPC_TYPE_ARRAY) {
		_xpc_array_dispose((struct xpc_array_s *)obj);
	} else if (type == XPC_TYPE_FD) {
		close(((struct xpc_fd_s *)obj)->fd);
	} else if (type == XPC_TYPE_MACH_RECV) {
		mach_port_t p = ((struct xpc_mach_recv_s *)obj)->port;
		if (MACH_PORT_VALID(p)) {
			mach_port_mod_refs(mach_task_self(), p, MACH_PORT_RIGHT_RECEIVE, -1);
		}
	} else if (type == XPC_TYPE_MACH_SEND) {
		mach_port_deallocate(mach_task_self(), ((struct xpc_mach_send_s *)obj)->port);
	} else if (type == (xpc_type_t)&_xpc_type_bundle) {
		_xpc_bundle_dispose(obj);
	} else if (type == XPC_TYPE_CONNECTION) {
		_xpc_connection_dispose(obj);
	} else if (type == (xpc_type_t)&_xpc_type_pipe) {
		_xpc_pipe_dispose(obj);
	} else if (type == XPC_TYPE_ENDPOINT) {
		mach_port_deallocate(mach_task_self(), ((struct xpc_endpoint_s *)obj)->port);
	}
	_xpc_compat_dispose(obj);
	/* Strings and data keep their bytes inline; scalars own nothing. */
}

#pragma mark - Public object API

xpc_type_t
xpc_get_type(xpc_object_t object)
{
	return (xpc_type_t)object_getClass((id)object);
}

xpc_object_t
xpc_retain(xpc_object_t object)
{
	return os_retain(object);
}

void
xpc_release(xpc_object_t object)
{
	os_release(object);
}

const char *
xpc_type_get_name(xpc_type_t type)
{
	const char *name = class_getName((Class)type);

	if (strncmp(name, "OS_xpc_", 7) == 0) {
		return name + 7;
	}
	return name;
}
