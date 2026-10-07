/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "internal.h"
#include <mach/mach.h>
#include <mach/mig.h>
#include <mach/ndr.h>
#include <string.h>
extern kern_return_t debug_control_port_for_pid(mach_port_t, int, mach_port_t *);
API bool _os_trace_set_mode_for_pid(int pid, uint32_t mode)
{
	mach_port_t port = MACH_PORT_NULL;
	if (debug_control_port_for_pid(mach_task_self(), pid, &port) != KERN_SUCCESS || !port)
		return false;
	struct {
		mach_msg_header_t header;
		NDR_record_t ndr;
		uint32_t mode, interval, filter;
	} request = {0};
	request.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
	request.header.msgh_size = 44;
	request.header.msgh_remote_port = port;
	request.header.msgh_id = 50000;
	request.ndr = NDR_record;
	request.mode = mode;
	voucher_mach_msg_set(&request.header);
	kern_return_t result =
	    mach_msg(&request.header, MACH_SEND_MSG, 44, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
	mach_port_deallocate(mach_task_self(), port);
	return result == KERN_SUCCESS;
}
API bool _os_trace_get_mode_for_pid(int pid, uint32_t *out)
{
	mach_port_t port = MACH_PORT_NULL;
	if (debug_control_port_for_pid(mach_task_self(), pid, &port) != KERN_SUCCESS || !port)
		return false;
	union {
		mach_msg_header_t request;
		struct {
			mach_msg_header_t header;
			NDR_record_t ndr;
			int32_t result;
			uint32_t mode;
			uint64_t reserved;
			mach_msg_trailer_t trailer;
		} reply;
	} message = {0};
	mach_port_t reply_port = mig_get_reply_port();
	message.request.msgh_bits =
	    MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
	message.request.msgh_size = 24;
	message.request.msgh_remote_port = port;
	message.request.msgh_local_port = reply_port;
	message.request.msgh_id = 50002;
	voucher_mach_msg_set(&message.request);
	kern_return_t result = mach_msg(&message.request,
	    MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT, 24,
	    sizeof(message), reply_port, 1000, MACH_PORT_NULL);
	bool valid = result == KERN_SUCCESS &&
	    !(message.reply.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
	    message.reply.header.msgh_id == 50102 && message.reply.header.msgh_size == 48 &&
	    message.reply.header.msgh_remote_port == MACH_PORT_NULL && !message.reply.result;
	if (valid) {
		*out = message.reply.mode;
		mig_put_reply_port(reply_port);
	} else if (result != KERN_SUCCESS)
		mig_dealloc_reply_port(reply_port);
	else {
		mach_msg_destroy(&message.request);
		mig_put_reply_port(reply_port);
	}
	mach_port_deallocate(mach_task_self(), port);
	return valid;
}
