/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "../image.h"
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static unsigned checks, failures;
#define CHECK(x)                                                                                   \
	do {                                                                                       \
		checks++;                                                                          \
		if (!(x)) {                                                                        \
			if (failures++ < 20)                                                       \
				fprintf(stderr, "line %d: %s\n", __LINE__, #x);                    \
		}                                                                                  \
	} while (0)
typedef size_t (*infofn)(
    const void *, size_t, unsigned char *, struct finch_trace_image_info *, unsigned);
typedef int (*slicefn)(const void *, size_t, int (^)(const void *, size_t));
static infofn hi, fi;
static void compare(const void *p, size_t n, unsigned flags)
{
	unsigned char hu[16], fu[16];
	struct finch_trace_image_info a, b;
	memset(hu, 0xa5, 16);
	memset(fu, 0xa5, 16);
	memset(&a, 0xa5, sizeof(a));
	memset(&b, 0xa5, sizeof(b));
	size_t x = hi(p, n, hu, &a, flags), y = fi(p, n, fu, &b, flags);
	CHECK(x == y);
	CHECK(!memcmp(hu, fu, 16));
	CHECK(!memcmp(&a, &b, sizeof(a)));
	if ((x != y || memcmp(&a, &b, sizeof(a))) && failures < 20) {
		fprintf(stderr, "len %zu flags %u returns %zu/%zu\n", n, flags, x, y);
		for (unsigned j = 0; j < sizeof(a); j++)
			if (((unsigned char *)&a)[j] != ((unsigned char *)&b)[j])
				fprintf(stderr, "byte %u %02x/%02x\n", j, ((unsigned char *)&a)[j],
				    ((unsigned char *)&b)[j]);
	}
	memset(hu, 0xa5, 16);
	memset(fu, 0xa5, 16);
	CHECK(hi(p, n, hu, NULL, flags) == fi(p, n, fu, NULL, flags));
	CHECK(!memcmp(hu, fu, 16));
}
static size_t make(unsigned char *b, int wide, const char *segment, const char *section_name)
{
	memset(b, 0, 8192);
	struct mach_header *m = (void *)b;
	m->magic = wide ? MH_MAGIC_64 : MH_MAGIC;
	m->ncmds = 2;
	size_t header = wide ? 32 : 28, fixed = wide ? 72 : 56, ss = wide ? 80 : 68;
	unsigned char *s = b + header;
	*(uint32_t *)s = wide ? LC_SEGMENT_64 : LC_SEGMENT;
	*(uint32_t *)(s + 4) = fixed + ss;
	strcpy((char *)s + 8, segment);
	if (wide) {
		struct segment_command_64 *c = (void *)s;
		c->vmaddr = 0x100000000;
		c->filesize = 4096;
		c->nsects = 1;
		struct section_64 *t = (void *)(s + fixed);
		strcpy(t->sectname, section_name);
		strcpy(t->segname, segment);
		t->addr = c->vmaddr + 400;
		t->offset = 512;
		t->size = 32;
	} else {
		struct segment_command *c = (void *)s;
		c->vmaddr = 0x1000;
		c->filesize = 4096;
		c->nsects = 1;
		struct section *t = (void *)(s + fixed);
		strcpy(t->sectname, section_name);
		strcpy(t->segname, segment);
		t->addr = c->vmaddr + 400;
		t->offset = 512;
		t->size = 32;
	}
	struct uuid_command *u = (void *)(s + fixed + ss);
	u->cmd = LC_UUID;
	u->cmdsize = 24;
	for (int j = 0; j < 16; j++)
		u->uuid[j] = j + 1;
	m->sizeofcmds = fixed + ss + 24;
	return header + m->sizeofcmds;
}
int main(int argc, char **argv)
{
	void *h = dlopen("/usr/lib/system/libsystem_trace.dylib", RTLD_NOW | RTLD_LOCAL),
	     *f = dlopen(argc > 1 ? argv[1] : "build/userland/trace/image-test.dylib",
	         RTLD_NOW | RTLD_LOCAL);
	if (!h || !f) {
		fprintf(stderr, "%s\n", dlerror());
		return 2;
	}
	hi = (infofn)dlsym(h, "_os_trace_get_image_info");
	fi = (infofn)dlsym(f, "_os_trace_get_image_info");
	slicefn hs = (slicefn)dlsym(h, "_os_trace_macho_for_each_slice"),
	        fs = (slicefn)dlsym(f, "_os_trace_macho_for_each_slice");
	CHECK(hi && fi && hs && fs);
	unsigned char *b = calloc(1, 8192), *copy = malloc(8192);
	const char *segments[] = {"__TEXT", "__CTF", "__OS_LOG", "__DATA"};
	const char *sections[] = {"__cstring", "__oslogstring", "__asan_cstring", "__ctf",
	    "__string", "__const", "__other"};
	for (int wide = 0; wide < 2; wide++)
		for (int sg = 0; sg < 4; sg++)
			for (int sc = 0; sc < 7; sc++) {
				size_t header = wide ? 32 : 28, fixed = wide ? 72 : 56;
				size_t min = make(b, wide, segments[sg], sections[sc]);
				compare(b, 8192, 0);
				compare(b, min, 0);
				compare(b, 0, 1);
				memcpy(copy, b, 8192);
				for (int j = 0; j < 16; j++) {
					memcpy(b, copy, 8192);
					b[header + fixed + (wide ? 40 : 36) + j % 4] ^= 1u
					    << (j / 4);
					compare(b, 8192, 0);
				}
				memcpy(b, copy, 8192);
				for (size_t n = 0; n < min; n++)
					compare(b, n, 0);
			}
	/* Encryption commands, protected segments, and sanitizer fallback ranges. */
	for (int wide = 0; wide < 2; wide++) {
		size_t header = wide ? 32 : 28;
		size_t end = make(b, wide, "__TEXT", "__const");
		struct mach_header *m = (void *)b;
		*(uint32_t *)(b + header + (wide ? 68 : 52)) = 8;
		compare(b, 8192, 0);
		struct dylib_command *d = (void *)(b + end);
		d->cmd = LC_LOAD_DYLIB;
		d->cmdsize = 64;
		d->dylib.name.offset = 24;
		strcpy((char *)d + 24, "@rpath/libclang_rt.asan_osx_dynamic.dylib");
		m->ncmds++;
		m->sizeofcmds += 64;
		compare(b, 8192, 0);
		for (int j = 0; j < 2; j++) {
			struct encryption_info_command *e = (void *)(b + end + 64);
			e->cmd = wide ? LC_ENCRYPTION_INFO_64 : LC_ENCRYPTION_INFO;
			e->cmdsize = wide ? 24 : 20;
			e->cryptid = j;
			m->ncmds = 4;
			m->sizeofcmds = (uint32_t)(end - header + 64 + e->cmdsize);
			compare(b, 8192, 0);
		}
	}
	/* Fat containers call the block with exact ranges, and preserve its result. */
	for (int swap = 0; swap < 2; swap++)
		for (int count = 0; count < 5; count++)
			for (int stop = 0; stop < 6; stop++) {
				memset(b, 0, 8192);
				struct fat_header *fh = (void *)b;
				fh->magic = swap ? FAT_CIGAM : FAT_MAGIC;
				fh->nfat_arch = swap ? __builtin_bswap32(count) : count;
				struct fat_arch *a = (void *)(b + 8);
				for (int j = 0; j < count; j++) {
					a[j].offset =
					    swap ? __builtin_bswap32(200 + j * 80) : 200 + j * 80;
					a[j].size = swap ? __builtin_bswap32(64) : 64;
				}
				__block unsigned hc = 0, fc = 0;
				size_t storage[4][5] = {{0}};
				size_t *ho = storage[0], *fo = storage[1], *hn = storage[2],
				       *fn = storage[3];
				int x = hs(b, 8192, ^(const void *p, size_t n) {
				  ho[hc] = (const unsigned char *)p - b;
				  hn[hc] = n;
				  hc++;
				  return (int)hc == stop ? 17 : 0;
				});
				int y = fs(b, 8192, ^(const void *p, size_t n) {
				  fo[fc] = (const unsigned char *)p - b;
				  fn[fc] = n;
				  fc++;
				  return (int)fc == stop ? 17 : 0;
				});
				CHECK(x == y);
				CHECK(hc == fc);
				CHECK(!memcmp(ho, fo, 5 * sizeof(size_t)));
				CHECK(!memcmp(hn, fn, 5 * sizeof(size_t)));
				for (size_t n = 0; n < 300; n++) {
					x = hs(b, n, ^(const void *p, size_t z) {
					  (void)p;
					  (void)z;
					  return 0;
					});
					y = fs(b, n, ^(const void *p, size_t z) {
					  (void)p;
					  (void)z;
					  return 0;
					});
					CHECK(x == y);
				}
			}
	uint32_t magic[] = {
	    MH_MAGIC, MH_CIGAM, MH_MAGIC_64, MH_CIGAM_64, FAT_MAGIC_64, FAT_CIGAM_64, 0};
	for (unsigned j = 0; j < sizeof(magic) / 4; j++) {
		memset(b, 0, 8192);
		*(uint32_t *)b = magic[j];
		for (size_t n = 0; n < 50; n++)
			CHECK(hs(b, n, ^(const void *p, size_t z) {
			  CHECK(p == b && z == n);
			  return 73;
			}) == fs(b, n, ^(const void *p, size_t z) {
			  CHECK(p == b && z == n);
			  return 73;
			}));
	}
	for (uint32_t j = 0; j < _dyld_image_count(); j++) {
		const struct mach_header *m = _dyld_get_image_header(j);
		compare(m, 0, 1);
	}
	free(b);
	free(copy);
	printf("image ABI: %u checks, %u failures\n", checks, failures);
	return failures ? 1 : 0;
}
