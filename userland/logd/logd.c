/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-logd: the log daemon. Serves com.apple.logd with libdispatch's
 * firehose server, so every process's os_log messages (which Finch's
 * libsystem_trace writes into firehose buffers, in Apple's tracepoint
 * format) arrive here. Each log tracepoint is decoded the way Finch's library
 * encodes it (userland/libsystem/trace/transport.c), composed with
 * os_log_fmt_compose (private data redacted), and appended to the store
 * (logstore.h), which log(1) reads. Docs: docs/design/LOGD.md.
 */

#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <firehose/private.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <os/firehose_server_private.h>
#include <pthread.h>
#include <servers/bootstrap.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <uuid/uuid.h>

#include "logstore.h"

/* libsystem_trace SPI (the composer every process uses). */
struct trace_blob {
	void *data;
	uint32_t length, capacity, maximum;
	uint16_t flags;          /* 1: data is heap memory the blob owns */
	uint8_t binary, reserved;
};
void os_log_fmt_compose(struct trace_blob *blob, const char *format, uintptr_t mode,
    unsigned privacy, unsigned pointer_size, const uint8_t *records, const uint8_t *public_data,
    uint16_t public_size, const uint8_t *private_data, uint16_t private_size);
const uint8_t *os_log_fmt_extract_pubdata(const uint8_t *data, uint16_t size,
    const uint8_t **values, uint16_t *value_size);
extern bool _dyld_get_shared_cache_uuid(uuid_t uuid);
extern const void *_dyld_get_shared_cache_range(size_t *length);
void os_trace_set_mode(uint32_t mode);

/* libfirehose_server expects its Xcode-generated version string (it logs it). */
const unsigned char __libfirehose_serverVersionString[] = "@(#)PROGRAM:libfirehose_server  PROJECT:libdispatch-1542.100.32 (Finch)\n";

#define LOG_NAMESPACE      4      /* firehose_tracepoint_namespace_log */
#define LOADER_NAMESPACE   5      /* image load/unload records (stream 3) */
#define METADATA_SIZE      2048
#define DYNAMIC_FORMAT     0x80000000u

/* The server delivers IO and memory buffers on separate queues; decoding,
 * the image cache and the store are shared. */
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int store_fd = -1;
static bool debug;   /* FINCH_LOGD_DEBUG: report clients and chunks on stderr */
static uint64_t boot_wall_ns;     /* wall clock at continuous time 0 */
static mach_timebase_info_data_t timebase;
static uuid_t cache_uuid;
static uintptr_t cache_base;
static size_t cache_size;

#pragma mark - Images

/* A Mach-O file on disk, mapped, for reading format strings by VM offset. */
struct image_file {
	char *path;
	uuid_t uuid;
	const uint8_t *map;
	size_t size;
	const struct mach_header_64 *header;   /* inside map (the arm64e slice of a fat file) */
	struct image_file *next;
};
static struct image_file *images;

static const struct mach_header_64 *
thin_header(const uint8_t *map, size_t size)
{
	const struct fat_header *fh = (const void *)map;

	if (size >= sizeof(struct mach_header_64) && ((const struct mach_header_64 *)map)->magic == MH_MAGIC_64) {
		return (const void *)map;
	}
	if (size >= sizeof(*fh) && OSSwapBigToHostInt32(fh->magic) == FAT_MAGIC) {
		const struct fat_arch *a = (const void *)(fh + 1);
		for (uint32_t i = 0; i < OSSwapBigToHostInt32(fh->nfat_arch); i++) {
			uint32_t off = OSSwapBigToHostInt32(a[i].offset);
			if (OSSwapBigToHostInt32((uint32_t)a[i].cputype) == CPU_TYPE_ARM64 &&
			    off + sizeof(struct mach_header_64) <= size) {
				return (const void *)(map + off);
			}
		}
	}
	return NULL;
}

static void
header_uuid(const struct mach_header_64 *h, uuid_t out)
{
	const uint8_t *p = (const uint8_t *)(h + 1);

	uuid_clear(out);
	for (uint32_t i = 0; i < h->ncmds; i++) {
		const struct load_command *lc = (const void *)p;
		if (lc->cmd == LC_UUID) {
			memcpy(out, ((const struct uuid_command *)lc)->uuid, 16);
			return;
		}
		p += lc->cmdsize;
	}
}

static struct image_file *
image_open(const char *path)
{
	struct image_file *f;
	struct stat st;
	int fd;

	for (f = images; f; f = f->next) {
		if (strcmp(f->path, path) == 0) return f->header ? f : NULL;
	}
	f = calloc(1, sizeof(*f));
	f->path = strdup(path);
	f->next = images;
	images = f;
	if ((fd = open(path, O_RDONLY | O_CLOEXEC)) < 0) return NULL;
	if (fstat(fd, &st) == 0 && st.st_size > 0) {
		void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
		if (m != MAP_FAILED) {
			f->map = m;
			f->size = (size_t)st.st_size;
			f->header = thin_header(f->map, f->size);
			if (f->header) header_uuid(f->header, f->uuid);
		}
	}
	close(fd);
	return f->header ? f : NULL;
}

/* The C string at `offset` from the image's mach header (its __TEXT start). */
static const char *
image_string(struct image_file *f, uint64_t offset)
{
	const uint8_t *p = (const uint8_t *)(f->header + 1), *base = (const uint8_t *)f->header;
	uint64_t text = 0, want;
	bool have_text = false;

	for (uint32_t i = 0; i < f->header->ncmds; i++, p += ((const struct load_command *)p)->cmdsize) {
		const struct segment_command_64 *s = (const void *)p;
		if (s->cmd == LC_SEGMENT_64 && strcmp(s->segname, "__TEXT") == 0) {
			text = s->vmaddr;
			have_text = true;
		}
	}
	if (!have_text) return NULL;
	want = text + offset;
	p = (const uint8_t *)(f->header + 1);
	for (uint32_t i = 0; i < f->header->ncmds; i++, p += ((const struct load_command *)p)->cmdsize) {
		const struct segment_command_64 *s = (const void *)p;
		if (s->cmd != LC_SEGMENT_64 || want < s->vmaddr || want >= s->vmaddr + s->filesize) continue;
		uint64_t at = s->fileoff + (want - s->vmaddr);
		const uint8_t *start = base + at;
		if (start < f->map || start >= f->map + f->size) return NULL;
		if (!memchr(start, 0, (size_t)(f->map + f->size - start))) return NULL;
		return (const char *)start;
	}
	return NULL;
}

#pragma mark - Clients

struct client_image {
	uuid_t uuid;
	char *path;
	struct client_image *next;
};

struct client {
	pid_t pid;
	char *path;                 /* main executable */
	const char *name;           /* its last component */
	bool same_cache;            /* uses the shared cache logd has mapped */
	struct client_image *images;
};

static struct client *
client_for(firehose_client_t fc)
{
	struct client *c = firehose_client_get_context(fc);
	size_t size = 0;
	const uint8_t *md;

	if (c) return c;
	c = calloc(1, sizeof(*c));
	firehose_client_get_unique_pid(fc, &c->pid);
	md = firehose_client_get_metadata_buffer(fc, &size);
	if (md && size >= 41 + 2) {
		c->path = strndup((const char *)md + 41, size - 41);
		c->same_cache = uuid_compare(md + 24, cache_uuid) == 0;
	} else {
		c->path = strdup("?");
	}
	const char *slash = strrchr(c->path, '/');
	c->name = slash ? slash + 1 : c->path;
	firehose_client_set_context(fc, c);
	return c;
}

static void
client_free(struct client *c)
{
	for (struct client_image *i = c->images, *n; i; i = n) {
		n = i->next;
		free(i->path);
		free(i);
	}
	free(c->path);
	free(c);
}

/* The subsystem and category registered under `id` in the client's metadata page. */
static void
log_names(firehose_client_t fc, uint16_t id, const char **subsystem, const char **category)
{
	size_t size = 0;
	const uint8_t *md = firehose_client_get_metadata_buffer(fc, &size);
	uint16_t path_len, used;

	*subsystem = *category = "";
	if (!md || size < 41 + 6) return;
	memcpy(&path_len, md + 2, 2);
	memcpy(&used, md + 4, 2);
	for (size_t at = path_len; at + 4 <= used && 41 + at + 4 <= size;) {
		const uint8_t *e = md + 41 + at;
		uint16_t entry_id;
		size_t n = 4 + e[2] + e[3];
		memcpy(&entry_id, e, 2);
		if (41 + at + n > size) return;
		if (entry_id == id) {
			*subsystem = (const char *)e + 4;
			*category = (const char *)e + 4 + e[2];
			return;
		}
		at += n + (n & 1);
	}
}

#pragma mark - Store

static void
store_open(void)
{
	mkdir("/var/log/finch", 0755);
	store_fd = open(LOGSTORE_PATH, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
}

static void
store_append(uint8_t type, uint64_t time_ns, uint64_t thread, pid_t pid, const char *process,
    const char *subsystem, const char *category, const char *message)
{
	size_t pl = strlen(process), sl = strlen(subsystem), cl = strlen(category), ml = strlen(message);
	size_t size = sizeof(struct logstore_record) + pl + sl + cl + ml + 4;
	struct logstore_record *r;
	struct stat st;

	size = (size + 7) & ~(size_t)7;
	if (store_fd < 0 || (r = calloc(1, size)) == NULL) return;
	r->size = (uint32_t)size;
	r->type = type;
	r->time_ns = time_ns;
	r->thread = thread;
	r->pid = pid;
	r->process_len = (uint16_t)pl;
	r->subsystem_len = (uint16_t)sl;
	r->category_len = (uint16_t)cl;
	r->message_len = (uint32_t)ml;
	char *s = r->strings;
	memcpy(s, process, pl + 1); s += pl + 1;
	memcpy(s, subsystem, sl + 1); s += sl + 1;
	memcpy(s, category, cl + 1); s += cl + 1;
	memcpy(s, message, ml + 1);
	write(store_fd, r, size);
	free(r);
	if (fstat(store_fd, &st) == 0 && st.st_size > LOGSTORE_MAX) {
		rename(LOGSTORE_PATH, LOGSTORE_PATH ".0");
		close(store_fd);
		store_open();
	}
}

#pragma mark - Decoding

static uint64_t
read_le(const uint8_t *p, size_t n)
{
	uint64_t v = 0;
	for (size_t i = 0; i < n; i++) v |= (uint64_t)p[i] << (8 * i);
	return v;
}

static const char *
client_image_path(struct client *c, const uuid_t uuid)
{
	for (struct client_image *i = c->images; i; i = i->next) {
		if (uuid_compare(i->uuid, uuid) == 0) return i->path;
	}
	return NULL;
}

/* Image load records (transport.c image_event): 32-byte record (uuid first), then the path. */
static void
loader_event(struct client *c, uint8_t type, const uint8_t *data, size_t len)
{
	if (type != 1 || len < 33 || memchr(data + 32, 0, len - 32) == NULL) return;
	if (client_image_path(c, data)) return;
	struct client_image *i = calloc(1, sizeof(*i));
	memcpy(i->uuid, data, 16);
	i->path = strdup((const char *)data + 32);
	i->next = c->images;
	c->images = i;
}

static void
log_event(firehose_client_t fc, struct client *c, firehose_tracepoint_t ft, uint64_t stamp)
{
	uint64_t id = ft->ft_id.ftid_value;
	uint8_t type = (uint8_t)(id >> 8);
	uint16_t flags = (uint16_t)(id >> 16);
	uint32_t code = (uint32_t)(id >> 32);
	const uint8_t *p = ft->ft_data, *end = ft->ft_data + ft->ft_length;
	const char *format = NULL, *subsystem = "", *category = "";
	uint64_t format_offset = code & ~DYNAMIC_FORMAT;
	struct image_file *image = NULL;
	uint8_t uuid[16];
	char buf[1024], fallback[96];

	/* Location prefix: where the call (and its format string) is. */
	switch (flags & 0xe) {
	case 4:   /* shared cache, 4- or 6-byte pc offset */
		p += 4;
		break;
	case 12:
		p += 6;
		break;
	case 2:   /* main executable */
		p += 4;
		image = image_open(c->path);
		break;
	case 10:  /* another image, by UUID */
		if (end - p < 20) return;
		memcpy(uuid, p + 4, 16);
		p += 20;
		if (client_image_path(c, uuid)) image = image_open(client_image_path(c, uuid));
		break;
	case 8:   /* absolute */
		p += 6;
		break;
	default:
		return;
	}
	if (flags & 0x20) {       /* format offset bits 31-46 */
		if (end - p < 2) return;
		format_offset |= read_le(p, 2) << 31;
		p += 2;
	}
	if (flags & 0x200) {      /* the log's subsystem and category */
		if (end - p < 2) return;
		log_names(fc, (uint16_t)read_le(p, 2), &subsystem, &category);
		p += 2;
	}
	if (flags & 0x800) {      /* oversize: the payload went to com.apple.logd.events */
		store_append(type, stamp, ft->ft_thread, c->pid, c->name, subsystem, category,
		    "<oversize message not captured>");
		return;
	}
	if (p > end) return;

	if (code == DYNAMIC_FORMAT) {
		/* Composed by the client: one string record. */
		if (end - p > 8 && memchr(p + 8, 0, (size_t)(end - p - 8))) {
			store_append(type, stamp, ft->ft_thread, c->pid, c->name, subsystem, category,
			    (const char *)p + 8);
		}
		return;
	}
	if ((flags & 0xe) == 4 || (flags & 0xe) == 12) {
		if (c->same_cache && format_offset < cache_size) {
			format = (const char *)(cache_base + format_offset);
		}
	} else if (image) {
		format = image_string(image, format_offset);
	}
	if (format == NULL) {
		snprintf(fallback, sizeof(fallback), "<format string not found: %s+%#llx>",
		    image ? image->path : (flags & 0xe) == 4 || (flags & 0xe) == 12 ? "shared cache" : "?",
		    (unsigned long long)format_offset);
		store_append(type, stamp, ft->ft_thread, c->pid, c->name, subsystem, category, fallback);
		return;
	}

	const uint8_t *values = NULL;
	uint16_t value_size = 0;
	const uint8_t *records = os_log_fmt_extract_pubdata(p, (uint16_t)(end - p), &values, &value_size);
	struct trace_blob blob = { buf, 0, sizeof(buf), 64 * 1024, 0, 0, 0 };
	buf[0] = 0;
	os_log_fmt_compose(&blob, format, 2, 0, 8, records, values, value_size, NULL, 0);
	store_append(type, stamp, ft->ft_thread, c->pid, c->name, subsystem, category, blob.data);
	if (blob.flags & 1) free(blob.data);
}

static void
chunk_received(firehose_client_t fc, firehose_chunk_t fbc)
{
	struct client *c = client_for(fc);
	firehose_tracepoint_t ft;

	/* The kernel's buffers (pid 0) locate format strings in the kernel
	 * collection, which logd doesn't read yet; skip them rather than store
	 * placeholders. */
	if (c->pid == 0) return;

	firehose_tracepoint_foreach(ft, fbc) {
		uint64_t ticks = fbc->fc_timestamp + ft->ft_timestamp_delta;
		uint64_t stamp = boot_wall_ns + ticks * timebase.numer / timebase.denom;
		uint8_t ns = (uint8_t)ft->ft_id.ftid_value;
		uint8_t type = (uint8_t)(ft->ft_id.ftid_value >> 8);
		if (ns == LOG_NAMESPACE) {
			log_event(fc, c, ft, stamp);
		} else if (ns == LOADER_NAMESPACE && type == 1) {
			/* transport.c image_event: code 1 is a load, 2 an unload. */
			loader_event(c, (uint8_t)(ft->ft_id.ftid_value >> 32), ft->ft_data, ft->ft_length);
		}
	}
}

int
main(void)
{
	mach_port_t port = MACH_PORT_NULL;
	struct timespec now;
	kern_return_t kr;

	/* logd mustn't send its own messages to itself. */
	os_trace_set_mode(0x100);

	mach_timebase_info(&timebase);
	clock_gettime(CLOCK_REALTIME, &now);
	boot_wall_ns = (uint64_t)now.tv_sec * NSEC_PER_SEC + (uint64_t)now.tv_nsec -
	    mach_continuous_time() * timebase.numer / timebase.denom;
	_dyld_get_shared_cache_uuid(cache_uuid);
	cache_base = (uintptr_t)_dyld_get_shared_cache_range(&cache_size);

	if ((kr = bootstrap_check_in(bootstrap_port, "com.apple.logd", &port)) != KERN_SUCCESS) {
		fprintf(stderr, "finch-logd: bootstrap_check_in com.apple.logd: %s\n", bootstrap_strerror(kr));
		return 1;
	}
	store_open();
	debug = getenv("FINCH_LOGD_DEBUG") != NULL;
	setvbuf(stderr, NULL, _IONBF, 0);
	if (debug) {
		fprintf(stderr, "finch-logd: commpage trace word %#x\n",
		    *(const volatile uint32_t *)(uintptr_t)UINT64_C(0xfffffc104));
	}
	firehose_server_init(port, ^(firehose_client_t fc, firehose_event_t event,
	    firehose_chunk_t page, firehose_chunk_pos_u pos) {
		(void)pos;
		pthread_mutex_lock(&lock);
		if (debug) {
			pid_t pid = 0;
			if (fc) firehose_client_get_unique_pid(fc, &pid);
			fprintf(stderr, "finch-logd: event %lu from pid %d\n", (unsigned long)event, pid);
		}
		switch (event) {
		case FIREHOSE_EVENT_IO_BUFFER_RECEIVED:
		case FIREHOSE_EVENT_MEM_BUFFER_RECEIVED:
			chunk_received(fc, page);
			break;
		case FIREHOSE_EVENT_CLIENT_CONNECTED:
			client_for(fc);
			break;
		case FIREHOSE_EVENT_CLIENT_FINALIZE: {
			struct client *c = firehose_client_get_context(fc);
			if (c) client_free(c);
			firehose_client_set_context(fc, NULL);
			break;
		}
		default:
			break;
		}
		pthread_mutex_unlock(&lock);
	});
	firehose_server_resume();
	dispatch_main();
}
