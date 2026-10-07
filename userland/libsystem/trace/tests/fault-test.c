#include "../fault.h"
#include "../state.h"
#include <dlfcn.h>
#include <ptrauth.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
static unsigned checks, created, adopted, released, requests, reports, banners, callbacks;
static uint32_t mode;
static bool development, lazy, enabled = true;
static void *current = (void *)7;
static const char *text = "saved message";
static struct finch_state_hints hints;
static uint8_t ttl_seen;
static const void *image_seen;
static unsigned char report[2048];
static uint32_t report_size;
static uint64_t report_flags;
static const char *report_format;
static struct finch_trace_callback_info callback_info[4];
static unsigned callback_order[4];
struct finch_log _os_log_default;
#define CHECK(x)                                                                                   \
	do {                                                                                       \
		checks++;                                                                          \
		if (!(x)) {                                                                        \
			fprintf(stderr, "FAIL line %u: %s\n", __LINE__, #x);                       \
			exit(1);                                                                   \
		}                                                                                  \
	} while (0)
bool _os_trace_mode_match_4tests(uint32_t m)
{
	return !!(mode & m);
}
bool _os_trace_is_development_build(void)
{
	return development;
}
const void *dyld_image_header_containing_address(const void *p)
{
	CHECK(p != NULL);
	return (void *)33;
}
void *_os_activity_create(const void *image, const char *name, void *parent, unsigned flags)
{
	CHECK(image == (void *)33);
	CHECK(!strcmp(name, "Activity for state dumps"));
	CHECK(parent == (void *)-3 && flags == 0);
	created++;
	return (void *)9;
}
void *voucher_adopt(void *v)
{
	void *old = current;
	current = v;
	adopted++;
	return old;
}
uint64_t voucher_get_activity_id(void *v, uint64_t *p)
{
	CHECK(v == (void *)9);
	CHECK(p == NULL);
	return 998877;
}
void os_release(void *v)
{
	CHECK(v == (void *)9);
	released++;
}
void finch_trace_state_request(uint64_t aid, const void *p, uint8_t ttl, const void *image)
{
	CHECK(aid == 998877 && current == (void *)9);
	hints = *(const struct finch_state_hints *)p;
	ttl_seen = ttl;
	image_seen = image;
	requests++;
}
char *finch_log_compose(
    const char *format, const uint8_t *data, size_t size, int error, char *buffer, size_t capacity)
{
	(void)format;
	(void)data;
	(void)size;
	(void)error;
	CHECK(!buffer && !capacity);
	return strdup(text);
}
void os_fault_with_payload(uint32_t name_space, uint64_t code, const void *payload, uint32_t size,
    const char *format, uint64_t flags)
{
	CHECK(name_space == 18 && code == 5);
	CHECK(size <= sizeof report);
	CHECK(current == (void *)7);
	memcpy(report, payload, size);
	report_size = size;
	report_flags = flags;
	report_format = format;
	reports++;
}
bool finch_trace_lazy_initialized(void)
{
	return lazy;
}
bool os_log_type_enabled(struct finch_log *log, uint8_t type)
{
	CHECK(log == &_os_log_default && type == 17);
	return enabled;
}
void _os_log_fault_impl(const void *image, struct finch_log *log, uint8_t type, const char *format,
    const void *data, uint32_t size)
{
	CHECK(image == (void *)33 && log == &_os_log_default && type == 17);
	CHECK(!strcmp(format, "QUARANTINED DUE TO HIGH LOGGING VOLUME"));
	CHECK(size == 2 && !((const unsigned char *)data)[0] && !((const unsigned char *)data)[1]);
	banners++;
}
static void fault_callback(const struct finch_trace_callback_info *info)
{
	CHECK(current == (void *)7);
	CHECK(callbacks < 4);
	callback_info[callbacks] = *info;
	callback_order[callbacks++] = 1;
	CHECK(!strcmp(info->message, text));
}
static void test_callback(const struct finch_trace_callback_info *info)
{
	CHECK(current == (void *)7);
	CHECK(callbacks < 4);
	callback_info[callbacks] = *info;
	callback_order[callbacks++] = 2;
	CHECK(!strcmp(info->message, text));
}
static uint32_t word(size_t n)
{
	uint32_t v;
	memcpy(&v, report + n, 4);
	return v;
}
int main(void)
{
	for (unsigned option = 0; option < 4; option++)
		for (unsigned env = 0; env < 5; env++)
			for (unsigned dev = 0; dev < 2; dev++)
				for (unsigned first = 0; first < 2; first++) {
					bool want = option == 2 ||
					    (option == 1 &&
					        (env == 2 || (env != 3 && dev && first)));
					CHECK(finch_trace_fault_report_enabled(
					          option << 23, env, dev, first) == want);
				}
	struct finch_log log = {0};
	struct finch_log_pack pack = {
	    .image = (void *)55, .pc = (void *)99, .format = "literal %s", .error = 17};
	uint8_t data[2] = {0};
	for (unsigned type = 0; type < 256; type++)
		for (unsigned unreliable = 0; unreliable < 2; unreliable++) {
			unsigned before = requests;
			struct finch_trace_fault_scope scope = finch_trace_fault_begin(
			    &log, type, &pack, data, 2, unreliable, false, 14);
			bool want = !unreliable && ((type & 0x7f) == 17 || (type & 0x80));
			CHECK(scope.active == want);
			CHECK(requests == before + want);
			if (want) {
				CHECK(hints.version == 1 && hints.reserved == 0 &&
				    hints.data == 0 && hints.flags == 1);
				CHECK(hints.type == ((type & 0x7f) == 17 ? 2 : 1));
				CHECK(ttl_seen == 14 && image_seen == (void *)55);
				CHECK(current == (void *)9);
			}
			finch_trace_fault_end(&scope);
			CHECK(current == (void *)7);
			CHECK(!scope.active && !scope.previous);
			finch_trace_fault_end(&scope);
		}
	CHECK(created == released && adopted == created * 2);
	mode = 0x100;
	unsigned before = requests;
	struct finch_trace_fault_scope scope =
	    finch_trace_fault_begin(&log, 17, &pack, data, 2, false, true, 1);
	CHECK(!scope.active && requests == before);
	mode = 0;
	unsigned char names[256] = {0};
	struct finch_log_names *n = (void *)names;
	n->subsystem_size = 4;
	n->category_size = 4;
	memcpy(n->names, "sub\0cat\0", 8);
	log.names = n;
	log.options = UINT64_C(0x3000000) << 32;
	scope = finch_trace_fault_begin(&log, 17, &pack, data, 2, false, true, 7);
	CHECK(reports == 1);
	CHECK(word(0) == 1 && word(4) == 0 && word(8) == 20 && word(12) == 24 && word(16) == 28);
	CHECK(!strcmp((char *)report + 20, "sub") && !strcmp((char *)report + 24, "cat") &&
	    !strcmp((char *)report + 28, text));
	CHECK(report_size == 28 + strlen(text) + 1 && report_flags == 0x800 &&
	    report_format == pack.format);
	finch_trace_fault_end(&scope);
	char longtext[4096];
	memset(longtext, 'x', sizeof longtext);
	longtext[sizeof longtext - 1] = 0;
	text = longtext;
	scope = finch_trace_fault_begin(&log, 17, &pack, data, 2, false, true, 7);
	CHECK(reports == 2 && report_size == 2048);
	CHECK(!memcmp(report + 2044, "...", 4));
	finch_trace_fault_end(&scope);
	text = "saved message";
	callbacks = 0;
	errno = EDOM;
	finch_trace_fault_callbacks(&log, 17, &pack, data, 2, fault_callback, test_callback);
	CHECK(errno == EDOM);
	CHECK(callbacks == 2 && callback_order[0] == 1 && callback_order[1] == 2);
	CHECK(callback_info[0].version == 1 && callback_info[0].reserved == 0 &&
	    callback_info[0].log == &log && callback_info[0].format == pack.format &&
	    callback_info[0].pc == pack.pc && callback_info[0].type == 17);
	CHECK(!strcmp(callback_info[0].subsystem, "sub") &&
	    !strcmp(callback_info[0].category, "cat"));
	/* The host callback helper can be compared without sending any log or fault. */
	void *host = dlopen("/usr/lib/system/libsystem_trace.dylib", RTLD_NOW | RTLD_LOCAL);
	void *symbol = dlsym(host, "_os_activity_stream_entry_encode");
	Dl_info address;
	CHECK(dladdr(symbol, &address));
	void (*invoke)(const void *, const void *, uint8_t, void *, void *) =
	    ptrauth_sign_unauthenticated(
	        (void *)((uintptr_t)address.dli_fbase + 0x1a35c), ptrauth_key_function_pointer, 0);
	unsigned char state[80] = {0};
	const char *blob = text;
	const void *blobptr = &blob;
	memcpy(state + 24, &blobptr, 8);
	finch_trace_message_callback callback = test_callback;
	struct finch_trace_callback_info ours = callback_info[1];
	callbacks = 0;
	invoke(&pack, &log, 0x91, state, &callback);
	CHECK(callbacks == 1);
	callback_info[0].message = ours.message;
	CHECK(!memcmp(&ours, callback_info, sizeof ours));
	callbacks = 0;
	finch_trace_fault_callbacks(&log, 16, &pack, data, 2, fault_callback, test_callback);
	CHECK(callbacks == 1 && callback_order[0] == 2);
	const char *sub = "com.apple.runtime-issues", *cat = "SkipRuntimeIssues";
	n->subsystem_size = strlen(sub) + 1;
	n->category_size = strlen(cat) + 1;
	strcpy(n->names, sub);
	strcpy(n->names + n->subsystem_size, cat);
	callbacks = 0;
	finch_trace_fault_callbacks(&log, 17, &pack, data, 2, fault_callback, test_callback);
	CHECK(callbacks == 1 && callback_order[0] == 2);
	CHECK(!finch_trace_is_quarantined());
	xpc_object_t packet = xpc_dictionary_create(NULL, NULL, 0);
	finch_trace_quarantine_packet(packet, 0);
	CHECK(!xpc_dictionary_get_value(packet, "quarantined"));
	lazy = false;
	finch_trace_quarantine();
	CHECK(finch_trace_is_quarantined() && !banners);
	finch_trace_quarantine_packet(packet, 3);
	CHECK(!xpc_dictionary_get_value(packet, "quarantined"));
	finch_trace_quarantine_packet(packet, 0);
	CHECK(xpc_dictionary_get_bool(packet, "quarantined"));
	lazy = true;
	enabled = false;
	finch_trace_quarantine();
	CHECK(!banners);
	enabled = true;
	finch_trace_quarantine();
	CHECK(banners == 1);
	xpc_release(packet);
	printf("%u fault/state/quarantine checks passed; crash reporting mocked\n", checks);
	return 0;
}
