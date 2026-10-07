/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "internal.h"
#include "fault.h"
#include "state.h"
#include <Block.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/ndr.h>
#include <uuid/uuid.h>
extern uint32_t os_trace_get_mode(void);
extern const void *dyld_image_header_containing_address(const void *);
extern bool _dyld_get_image_uuid(const void *, unsigned char *);
extern bool _dyld_get_shared_cache_uuid(unsigned char *);
extern kern_return_t debug_control_port_for_pid(mach_port_t, int, mach_port_t *);
extern uint64_t voucher_get_activity_id(void *, uint64_t *);
extern void _os_activity_initiate(const void *, const char *, unsigned, void (^)(void));
struct state_entry {
	struct state_entry *next;
	uint64_t token;
	finch_state_handler handler;
	dispatch_queue_t queue;
	const void *image;
	time_t last;
	unsigned interval;
	bool removed, inflight;
};
static pthread_mutex_t state_lock = PTHREAD_MUTEX_INITIALIZER;
static struct state_entry *head, **tail = &head;
static uint64_t next_token = 1;
static bool busy;
static dispatch_queue_t state_queue;
static dispatch_once_t queue_once;
static void queue_init(void *unused)
{
	(void)unused;
	state_queue = dispatch_queue_create("finch.trace.state", DISPATCH_QUEUE_SERIAL);
}
static void entry_free(struct state_entry *e)
{
	Block_release(e->handler);
	dispatch_release(e->queue);
	free(e);
}
API uint64_t os_state_add_handler(dispatch_queue_t queue, finch_state_handler handler)
{
	if (os_trace_get_mode() & 0x100)
		return 0;
	struct state_entry *e = calloc(1, sizeof(*e));
	if (!e)
		return 0;
	e->queue = queue;
	dispatch_retain(queue);
	e->handler = Block_copy(handler);
	e->image = dyld_image_header_containing_address(__builtin_return_address(0));
	e->interval = 1;
	pthread_mutex_lock(&state_lock);
	e->token = next_token++;
	*tail = e;
	tail = &e->next;
	pthread_mutex_unlock(&state_lock);
	return e->token;
}
API void os_state_remove_handler(uint64_t token)
{
	if (os_trace_get_mode() & 0x100)
		return;
	pthread_mutex_lock(&state_lock);
	struct state_entry **at = &head, *e = NULL;
	while (*at && ((*at)->token != token || (*at)->removed))
		at = &(*at)->next;
	if (*at) {
		e = *at;
		if (e->inflight) {
			e->removed = true;
			e = NULL;
		} else {
			*at = e->next;
			if (!*at)
				tail = at;
		}
	}
	pthread_mutex_unlock(&state_lock);
	if (e)
		entry_free(e);
}
static void send_entries(xpc_object_t entries, uint64_t activity, uint32_t hint_type)
{
	xpc_object_t packet = xpc_dictionary_create(NULL, NULL, 0);
	finch_trace_quarantine_packet(packet, hint_type);
	xpc_dictionary_set_uint64(packet, "operation", 2);
	uuid_t uuid;
	if (_dyld_get_shared_cache_uuid(uuid))
		xpc_dictionary_set_uuid(packet, "dsc_uuid", uuid);
	xpc_dictionary_set_uint64(packet, "aid", activity);
	xpc_dictionary_set_value(packet, "entries", entries);
	finch_trace_state_send(packet);
	xpc_release(packet);
}
void finch_trace_state_request(
    uint64_t activity, const void *hint_pointer, uint8_t ttl, const void *image)
{
	if (os_trace_get_mode() & 0x500)
		return;
	pthread_mutex_lock(&state_lock);
	if (busy || !head) {
		pthread_mutex_unlock(&state_lock);
		return;
	}
	size_t count = 0;
	for (struct state_entry *e = head; e; e = e->next)
		count++;
	struct state_entry **entries = malloc(count * sizeof(*entries));
	if (!entries) {
		pthread_mutex_unlock(&state_lock);
		return;
	}
	size_t i = 0;
	for (struct state_entry *e = head; e; e = e->next) {
		e->inflight = true;
		entries[i++] = e;
	}
	busy = true;
	pthread_mutex_unlock(&state_lock);
	struct finch_state_hints hints = *(const struct finch_state_hints *)hint_pointer;
	dispatch_once_f(&queue_once, NULL, queue_init);
	dispatch_async(state_queue, ^{
	  time_t now = time(NULL);
	  xpc_object_t batch = xpc_array_create(NULL, 0);
	  for (size_t k = 0; k < count; k++) {
		  struct state_entry *e = entries[k];
		  if (hints.type == 1 && e->image != image)
			  continue;
		  time_t elapsed = now - e->last;
		  if (elapsed < e->interval)
			  continue;
		  if (elapsed < e->interval + 10)
			  e->interval = (e->interval < 30 ? e->interval : 30) * 2;
		  else if (elapsed >= 70)
			  e->interval = 1;
		  e->last = now;
		  uuid_t uuid;
		  if (!_dyld_get_image_uuid(e->image, uuid))
			  continue;
		  __block struct finch_state_data *data = NULL;
		  dispatch_sync(e->queue, ^{
		    data = e->handler(&hints);
		  });
		  if (!data)
			  continue;
		  if (data->size >= 32569) {
			  free(data);
			  continue;
		  }
		  data->title[63] = data->object_type[63] = data->object_name[63] = 0;
		  xpc_object_t item = xpc_dictionary_create(NULL, NULL, 0);
		  xpc_dictionary_set_data(item, "data", data, sizeof(*data) + data->size);
		  free(data);
		  xpc_dictionary_set_uint64(item, "ts", mach_continuous_time());
		  xpc_dictionary_set_uuid(item, "uuid", uuid);
		  if (ttl)
			  xpc_dictionary_set_uint64(item, "ttl", ttl);
		  xpc_array_append_value(batch, item);
		  xpc_release(item);
		  if (xpc_array_get_count(batch) == 10) {
			  send_entries(batch, activity, hints.type);
			  xpc_release(batch);
			  batch = xpc_array_create(NULL, 0);
		  }
	  }
	  if (xpc_array_get_count(batch))
		  send_entries(batch, activity, hints.type);
	  xpc_release(batch);
	  pthread_mutex_lock(&state_lock);
	  for (size_t k = 0; k < count; k++)
		  entries[k]->inflight = false;
	  struct state_entry **at = &head, *discard = NULL;
	  while (*at) {
		  struct state_entry *e = *at;
		  if (e->removed) {
			  *at = e->next;
			  e->next = discard;
			  discard = e;
		  } else
			  at = &e->next;
	  }
	  tail = at;
	  busy = false;
	  pthread_mutex_unlock(&state_lock);
	  while (discard) {
		  struct state_entry *next = discard->next;
		  entry_free(discard);
		  discard = next;
	  }
	  free(entries);
	});
}
static atomic_flag request_busy = ATOMIC_FLAG_INIT;
API void _os_state_request_for_pidlist(const int *pids, unsigned count)
{
	if (atomic_flag_test_and_set_explicit(&request_busy, memory_order_acquire))
		return;
	_os_activity_initiate(dyld_image_header_containing_address(__builtin_return_address(0)),
	    "System-wide statedump", 0, ^{
	      uint64_t activity = voucher_get_activity_id((void *)(intptr_t)-3, NULL);
	      for (unsigned i = 0; i < count; i++) {
		      mach_port_t port = MACH_PORT_NULL;
		      if (debug_control_port_for_pid(mach_task_self(), pids[i], &port) !=
			      KERN_SUCCESS ||
			  !port)
			      continue;
		      struct {
			      mach_msg_header_t head;
			      NDR_record_t ndr;
			      uint64_t activity;
		      } message = {.head = {.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0),
			               .msgh_size = 40,
			               .msgh_remote_port = port,
			               .msgh_id = 50001},
			  .ndr = NDR_record,
			  .activity = activity};
		      kern_return_t result =
			  mach_msg(&message.head, MACH_SEND_MSG | MACH_SEND_TIMEOUT, 40, 0,
			      MACH_PORT_NULL, 50, MACH_PORT_NULL);
		      if (result == MACH_SEND_TIMED_OUT)
			      mach_msg_destroy(&message.head);
		      mach_port_deallocate(mach_task_self(), port);
	      }
	    });
	atomic_flag_clear_explicit(&request_busy, memory_order_release);
}
