/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../ring.h"
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x)                                                                                   \
	do {                                                                                       \
		if (!(x)) {                                                                        \
			fprintf(stderr, "line %d failed: %s\n", __LINE__, #x);                     \
			exit(1);                                                                   \
		}                                                                                  \
	} while (0)
struct api {
	int (*init)(struct rt_ring *, void *, void *, void *, uint32_t, size_t);
	int (*create)(struct rt_ring *, void *, uint32_t, size_t);
	int (*join)(struct rt_ring *, const void *, void *);
	size_t (*size)(size_t, size_t);
	int (*write)(struct rt_ring *, const void *, size_t);
	int (*message)(struct rt_ring *, const struct rt_piece *, size_t);
	int (*read)(struct rt_ring *, rt_read_fn, void *, uint32_t *, uint32_t *);
	int (*from)(
	    struct rt_ring *, uint32_t *, void *, void *, size_t, rt_dropped_fn, rt_iterate_fn);
	int (*iterate)(struct rt_ring *, void *, void *, size_t, rt_iterate_fn);
	int (*available)(const struct rt_ring *, uint32_t);
	void (*binit)(void *, size_t);
	int (*status)(const void *);
	void *(*header)(void *);
	void *(*resource)(void *, uint32_t);
	size_t (*rsize)(const void *, uint32_t);
	void *(*alloc)(void *, uint32_t, size_t);
	void *(*add)(void *, uint32_t, const void *, size_t);
	size_t (*required)(const size_t *, size_t);
	void (*biter)(void *, void (*)(const struct rt_resource *, void *), void *);
	unsigned (*config)(const char *);
};
static void load(struct api *a, void *h)
{
	*a = (struct api){dlsym(h, "RTLogRingBufferInit"), dlsym(h, "RTLogRingBufferCreateManaged"),
	    dlsym(h, "RTLogRingBufferJoinManaged"), dlsym(h, "RTLogRingBufferDataSize"),
	    dlsym(h, "RTLogRingBufferWriteBuffer"), dlsym(h, "RTLogRingBufferWriteMessage"),
	    dlsym(h, "RTLogRingBufferReadAt"), dlsym(h, "RTLogRingBufferIterateFrom"),
	    dlsym(h, "RTLogRingBufferIterate"), dlsym(h, "RTLogRingBufferIsDataAvailable"),
	    dlsym(h, "RTLogBufferInitialize"), dlsym(h, "RTLogBufferCheckStatus"),
	    dlsym(h, "RTLogBufferGetHeader"), dlsym(h, "RTLogBufferGetResource"),
	    dlsym(h, "RTLogBufferGetResourceSize"), dlsym(h, "RTLogBufferAllocateResource"),
	    dlsym(h, "RTLogBufferAddResource"), dlsym(h, "RTLogBufferRequiredStorageSize"),
	    dlsym(h, "RTLogBufferIterate"), dlsym(h, "RTLogConnectMemoryConfigFromString")};
}
struct record {
	uint32_t start, size;
	unsigned char data[1024];
};
struct reads {
	size_t count;
	struct record records[32];
};
static void read_callback(uint32_t start, const void *data, size_t size, void *p)
{
	struct reads *r = p;
	CHECK(r->count < 32 && size <= 1024);
	struct record *b = &r->records[r->count++];
	b->start = start;
	b->size = size;
	memcpy(b->data, data, size);
}
struct iters {
	size_t count, capacity, stop;
	unsigned lost;
	unsigned char data[8192];
};
static int iter_callback(void *buffer, void *p)
{
	struct iters *i = p;
	CHECK((i->count + 1) * i->capacity <= sizeof(i->data));
	memcpy(i->data + i->count * i->capacity, buffer, i->capacity);
	i->count++;
	return i->count < i->stop;
}
static void lost_callback(void *buffer, void *p, uint32_t lost)
{
	(void)buffer;
	((struct iters *)p)->lost += lost;
}
static void resource_callback(const struct rt_resource *r, void *p)
{
	struct reads *all = p;
	struct record *b = &all->records[all->count++];
	memcpy(b->data, r, sizeof(*r));
}
int main(int argc, char **argv)
{
	CHECK(argc == 2);
	void *h = dlopen("/usr/lib/system/libsystem_trace.dylib", RTLD_NOW | RTLD_LOCAL),
	     *f = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	CHECK(h && f);
	struct api a[2];
	load(a, h);
	load(a + 1, f);
	Dl_info info;
	CHECK(dladdr((void *)a[1].create, &info));
	CHECK(strstr(info.dli_fname, argv[1]));
	unsigned char input[1024];
	for (size_t i = 0; i < 1024; i++)
		input[i] = i * 13;
	for (uint32_t count = 1; count <= 32; count *= 2)
		for (size_t segment = 1; segment <= 32; segment *= 2) {
			size_t bytes = a[0].size(count, segment);
			CHECK(bytes == a[1].size(count, segment));
			unsigned char *storage[2] = {calloc(1, bytes + 32), calloc(1, bytes + 32)};
			struct rt_ring ring[2];
			memset(ring, 0xa5, sizeof(ring));
			for (int j = 0; j < 2; j++)
				CHECK(!a[j].create(&ring[j], storage[j], count, segment));
			CHECK(!memcmp(storage[0], storage[1], bytes + 32));
			uint32_t cursor[2] = {count + 1, count + 1};
			for (size_t turn = 0; turn < 50; turn++) {
				size_t n = (turn * 17 + 3) % (count * segment + 2);
				int ret[2], err[2];
				for (int j = 0; j < 2; j++) {
					errno = 0;
					if (turn % 2) {
						struct rt_piece p[] = {
						    {input, n / 2}, {input + n / 2, n - n / 2}};
						ret[j] = a[j].message(&ring[j], p, 2);
					} else
						ret[j] = a[j].write(&ring[j], input, n);
					err[j] = errno;
				}
				CHECK(ret[0] == ret[1] && err[0] == err[1]);
				if (memcmp(storage[0], storage[1], bytes + 32)) {
					fprintf(stderr, "storage c%u s%zu turn%zu n%zu\n", count,
					    segment, turn, n);
					for (size_t z = 0; z < bytes + 32; z++)
						if (storage[0][z] != storage[1][z])
							fprintf(stderr, "at %zu %02x %02x\n", z,
							    storage[0][z], storage[1][z]);
					return 1;
				}
				if (turn % 4 == 0) {
					struct reads reads[2] = {0};
					uint32_t dropped[2] = {0};
					for (int j = 0; j < 2; j++)
						ret[j] = a[1 - j].read(&ring[j], read_callback,
						    &reads[j], &cursor[j], &dropped[j]);
					CHECK(ret[0] == ret[1]);
					CHECK(cursor[0] == cursor[1] && dropped[0] == dropped[1]);
					CHECK(!memcmp(reads, reads + 1, sizeof(reads[0])));
				}
				CHECK(a[0].available(&ring[0], cursor[0]) ==
				    a[1].available(&ring[1], cursor[1]));
			}
			for (size_t capacity = 1; capacity <= count * segment; capacity *= 3) {
				unsigned char buffers[2][1024];
				memset(buffers, 0xc7, sizeof(buffers));
				struct iters it[2] = {0};
				uint32_t pos[2] = {cursor[0], cursor[0]};
				int r[2];
				for (int j = 0; j < 2; j++) {
					it[j].capacity = capacity;
					it[j].stop = 32;
					r[j] = a[j].from(&ring[j], &pos[j], &it[j], buffers[j],
					    capacity, lost_callback, iter_callback);
				}
				CHECK(r[0] == r[1] && pos[0] == pos[1]);
				CHECK(!memcmp(it, it + 1, sizeof(it[0])));
				memset(it, 0, sizeof(it));
				memset(buffers, 0xc7, sizeof(buffers));
				for (int j = 0; j < 2; j++) {
					it[j].capacity = capacity;
					it[j].stop = 2;
					r[j] = a[j].iterate(
					    &ring[j], &it[j], buffers[j], capacity, iter_callback);
				}
				CHECK(r[0] == r[1]);
				CHECK(!memcmp(it, it + 1, sizeof(it[0])));
			}
			struct rt_ring joined;
			CHECK(a[1].join(&joined, &ring[0], storage[0]));
			CHECK(!memcmp(&joined, &ring[0], sizeof(joined)));
			free(storage[0]);
			free(storage[1]);
		}
	for (uint32_t count = 0; count < 34; count++) {
		unsigned char memory[2][2048] = {0}, size[2][32] = {0};
		struct rt_ring ring[2];
		memset(ring, 0xa5, sizeof(ring));
		int r[2], e[2];
		for (int j = 0; j < 2; j++) {
			errno = 0;
			r[j] = a[j].create(&ring[j], memory[j], count, 8);
			e[j] = errno;
		}
		CHECK(r[0] == r[1] && e[0] == e[1]);
		for (int j = 0; j < 2; j++) {
			errno = 0;
			r[j] = a[j].init(&ring[j], size[j], memory[j], memory[j] + 256, count, 8);
			e[j] = errno;
		}
		CHECK(r[0] == r[1] && e[0] == e[1]);
		CHECK(!memcmp(size[0], size[1], 32));
		CHECK(!memcmp(memory[0], memory[1], 2048));
	}
	for (size_t count = 0; count < 17; count++) {
		size_t sizes[17];
		for (size_t i = 0; i < 17; i++)
			sizes[i] = i * 3 + 1;
		CHECK(a[0].required(sizes, count) == a[1].required(sizes, count));
	}
	_Alignas(8) unsigned char buffers[2][4096];
	memset(buffers, 0, sizeof(buffers));
	for (int j = 0; j < 2; j++)
		a[j].binit(buffers[j], 4096);
	CHECK(!memcmp(buffers[0], buffers[1], 4096));
	for (unsigned i = 0; i < 15; i++) {
		for (int j = 0; j < 2; j++) {
			void *p = a[j].add(buffers[j], i % 4, input, i * 3);
			CHECK(p == a[j].resource(buffers[j], i % 4) || i >= 4);
		}
		CHECK(!memcmp(buffers[0], buffers[1], 4096));
		for (unsigned t = 0; t < 20; t++) {
			void *p = a[0].resource(buffers[0], t), *q = a[1].resource(buffers[1], t);
			CHECK((p ? (char *)p - (char *)buffers[0] : -1) ==
			    (q ? (char *)q - (char *)buffers[1] : -1));
			CHECK(a[0].rsize(buffers[0], t) == a[1].rsize(buffers[1], t));
		}
	}
	struct reads rs[2] = {0};
	for (int j = 0; j < 2; j++)
		a[j].biter(buffers[j], resource_callback, &rs[j]);
	CHECK(!memcmp(rs, rs + 1, sizeof(rs[0])));
	for (size_t field = 0; field < 4; field++) {
		size_t offset[] = {0, 32, 40, 64};
		buffers[0][offset[field]] ^= 0x80;
		buffers[1][offset[field]] ^= 0x80;
		CHECK(a[0].status(buffers[0]) == a[1].status(buffers[1]));
		CHECK(!!a[0].header(buffers[0]) == !!a[1].header(buffers[1]));
		buffers[0][offset[field]] ^= 0x80;
		buffers[1][offset[field]] ^= 0x80;
	}
	const char *configs[] = {NULL, "default", "small", "medium", "large", "LARGE", "bad", ""};
	for (size_t i = 0; i < 8; i++)
		CHECK(a[0].config(configs[i]) == a[1].config(configs[i]));
	puts(
	    "RTLog: host ring bytes, wraparound, reads, mixed calls, iteration, resources and errors match");
	return 0;
}
