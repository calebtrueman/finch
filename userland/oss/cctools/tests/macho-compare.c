/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * macho-compare: Finch's libmacho against Apple's. Architecture tables
 * (NXGetAllArchInfos, lookups by name and by cputype), section and segment
 * lookups on every image loaded in this process, and byte-swapping.
 *
 *   macho-compare <path to Finch's libmacho.dylib>
 */

#include <dlfcn.h>
#include <mach-o/arch.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach-o/swap.h>
#include <stdio.h>
#include <string.h>

static unsigned long checks, failures;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { if (failures++ < 20) fprintf(stderr, "FAIL: " __VA_ARGS__); } } while (0)

struct api {
	const NXArchInfo *(*all)(void);
	const NXArchInfo *(*by_name)(const char *);
	const NXArchInfo *(*by_type)(cpu_type_t, cpu_subtype_t);
	uint8_t *(*sectiondata)(const struct mach_header_64 *, const char *, const char *, unsigned long *);
	uint8_t *(*segmentdata)(const struct mach_header_64 *, const char *, unsigned long *);
	const struct section_64 *(*sectbynamefromheader)(const struct mach_header_64 *, const char *, const char *);
	void (*swap_mh)(struct mach_header_64 *, enum NXByteOrder);
};

static void load(void *h, struct api *a)
{
	a->all = dlsym(h, "NXGetAllArchInfos");
	a->by_name = dlsym(h, "NXGetArchInfoFromName");
	a->by_type = dlsym(h, "NXGetArchInfoFromCpuType");
	a->sectiondata = dlsym(h, "getsectiondata");
	a->segmentdata = dlsym(h, "getsegmentdata");
	a->sectbynamefromheader = dlsym(h, "getsectbynamefromheader_64");
	a->swap_mh = dlsym(h, "swap_mach_header_64");
}

static int same_info(const NXArchInfo *x, const NXArchInfo *y)
{
	if (!x || !y) return x == y;
	return x->cputype == y->cputype && x->cpusubtype == y->cpusubtype && x->byteorder == y->byteorder &&
	       strcmp(x->name, y->name) == 0 && strcmp(x->description, y->description) == 0;
}

int main(int argc, char **argv)
{
	if (argc != 2) { fprintf(stderr, "usage: macho-compare <finch libmacho.dylib>\n"); return 2; }
	void *ha = dlopen("/usr/lib/system/libmacho.dylib", RTLD_NOW | RTLD_LOCAL), *hf = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!ha || !hf || ha == hf) { fprintf(stderr, "macho-compare: %s\n", dlerror()); return 2; }
	struct api A, F;
	load(ha, &A);
	load(hf, &F);

	const NXArchInfo *ia = A.all(), *iff = F.all();
	int na = 0, nf = 0;
	while (ia[na].name) na++;
	while (iff[nf].name) nf++;
	CHECK(na == nf, "arch table sizes %d vs %d\n", na, nf);
	for (int i = 0; i < na && i < nf; i++) {
		CHECK(same_info(&ia[i], &iff[i]), "arch %d: %s vs %s\n", i, ia[i].name, iff[i].name);
		CHECK(same_info(A.by_name(ia[i].name), F.by_name(ia[i].name)), "by name %s\n", ia[i].name);
		CHECK(same_info(A.by_type(ia[i].cputype, ia[i].cpusubtype), F.by_type(ia[i].cputype, ia[i].cpusubtype)),
		    "by type %s\n", ia[i].name);
	}
	static const char *names[] = { "arm64e", "arm64", "x86_64", "x86_64h", "arm64_32", "armv7k", "nonesuch", "i386", "any", "little", "big" };
	for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
		CHECK(same_info(A.by_name(names[i]), F.by_name(names[i])), "by name %s\n", names[i]);

	static const char *sects[][2] = { { "__TEXT", "__text" }, { "__TEXT", "__cstring" }, { "__DATA_CONST", "__got" },
	                                  { "__DATA", "__data" }, { "__TEXT", "__unwind_info" }, { "__NOPE", "__nope" } };
	for (uint32_t i = 0; i < _dyld_image_count(); i++) {
		const struct mach_header_64 *mh = (const void *)_dyld_get_image_header(i);
		for (size_t s = 0; s < sizeof(sects) / sizeof(sects[0]); s++) {
			unsigned long sa = 0, sf = 0;
			uint8_t *pa = A.sectiondata(mh, sects[s][0], sects[s][1], &sa), *pf = F.sectiondata(mh, sects[s][0], sects[s][1], &sf);
			CHECK(pa == pf && sa == sf, "getsectiondata %s,%s in image %u\n", sects[s][0], sects[s][1], i);
			CHECK(A.sectbynamefromheader(mh, sects[s][0], sects[s][1]) == F.sectbynamefromheader(mh, sects[s][0], sects[s][1]),
			    "getsectbynamefromheader_64 %s,%s\n", sects[s][0], sects[s][1]);
			pa = A.segmentdata(mh, sects[s][0], &sa);
			pf = F.segmentdata(mh, sects[s][0], &sf);
			CHECK(pa == pf && sa == sf, "getsegmentdata %s\n", sects[s][0]);
		}
		struct mach_header_64 x = *mh, y = *mh;
		A.swap_mh(&x, NXHostByteOrder() == NX_LittleEndian ? NX_BigEndian : NX_LittleEndian);
		F.swap_mh(&y, NXHostByteOrder() == NX_LittleEndian ? NX_BigEndian : NX_LittleEndian);
		CHECK(memcmp(&x, &y, sizeof(x)) == 0, "swap_mach_header_64\n");
	}
	printf("macho-compare: %lu checks, %lu failures\n", checks, failures);
	return failures != 0;
}
