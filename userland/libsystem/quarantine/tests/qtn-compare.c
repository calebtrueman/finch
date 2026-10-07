/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Differential test: Apple's libquarantine against Finch's.
 *   parse      init_with_data on generated labels: same result code and fields
 *   serialize  random records through the setters: same to_data bytes/length
 *   files      apply_to_fd with each library: same xattr; init_with_fd round trip
 *
 *   qtn-compare <finch libquarantine.dylib>
 */
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/xattr.h>
#include <unistd.h>

typedef void *qf_t;
struct lib {
	qf_t (*alloc)(void);
	void (*free)(qf_t);
	int (*init_data)(qf_t, const void *, size_t);
	int (*to_data)(qf_t, char *, size_t *);
	uint32_t (*gflags)(qf_t);
	int (*sflags)(qf_t, uint32_t);
	uint64_t (*gts)(qf_t);
	int (*sts)(qf_t, uint64_t);
	const char *(*gid)(qf_t);
	int (*sid)(qf_t, const char *);
	const void *(*gmd)(qf_t);
	size_t (*gmds)(qf_t);
	int (*smd)(qf_t, const void *, size_t);
	int (*apply_fd)(qf_t, int);
	int (*init_fd)(qf_t, int);
};

static void
load(struct lib *l, void *h)
{
#define S(f, n) l->f = dlsym(h, n)
	S(alloc, "_qtn_file_alloc"); S(free, "_qtn_file_free"); S(init_data, "_qtn_file_init_with_data");
	S(to_data, "_qtn_file_to_data"); S(gflags, "_qtn_file_get_flags"); S(sflags, "_qtn_file_set_flags");
	S(gts, "_qtn_file_get_timestamp"); S(sts, "_qtn_file_set_timestamp"); S(gid, "_qtn_file_get_identifier");
	S(sid, "_qtn_file_set_identifier"); S(gmd, "_qtn_file_get_metadata"); S(gmds, "_qtn_file_get_metadata_size");
	S(smd, "_qtn_file_set_metadata"); S(apply_fd, "_qtn_file_apply_to_fd"); S(init_fd, "_qtn_file_init_with_fd");
}

static int bad, checks;
#define EXPECT(c, ...) do { checks++; if (!(c)) { if (++bad <= 20) { printf("DIFF: "); printf(__VA_ARGS__); printf("\n"); } } } while (0)

static void
same_fields(struct lib *a, qf_t qa, struct lib *b, qf_t qb, const char *what)
{
	EXPECT(a->gflags(qa) == b->gflags(qb), "%s: flags %x vs %x", what, a->gflags(qa), b->gflags(qb));
	EXPECT(a->gts(qa) == b->gts(qb), "%s: ts", what);
	EXPECT(strcmp(a->gid(qa), b->gid(qb)) == 0, "%s: id [%s] vs [%s]", what, a->gid(qa), b->gid(qb));
	EXPECT(a->gmds(qa) == b->gmds(qb) && memcmp(a->gmd(qa), b->gmd(qb), a->gmds(qa)) == 0,
	    "%s: metadata (%zu vs %zu)", what, a->gmds(qa), b->gmds(qb));
	char da[8192], db[8192];
	size_t la = sizeof(da), lb = sizeof(db);
	int ra = a->to_data(qa, da, &la), rb = b->to_data(qb, db, &lb);
	EXPECT(ra == rb && (ra != 0 || (la == lb && strcmp(da, db) == 0)), "%s: to_data rc %d/%d [%s] vs [%s] len %zu/%zu",
	    what, ra, rb, da, db, la, lb);
}

static const char pieces[][12] = { ";", "\\x3b", "\\x", "\\", "\\xg1", "a", "Safari", " ", "\\x00", "\\xff", "ffff",
	"0083", "68e3b0a1", "1fff", "2000", "F2C9-ab", "/", "\\\\" };

static void
gen_label(char *out, size_t size, unsigned seed)
{
	srand(seed);
	size_t n = 0;
	if (rand() % 10) { out[n++] = 'q'; out[n++] = '/'; }
	int parts = rand() % 14;
	for (int i = 0; i < parts && n + 16 < size; i++) {
		int r = rand() % 4;
		if (r == 0) {
			out[n++] = (char)(1 + rand() % 255);
		} else {
			const char *p = pieces[rand() % (sizeof(pieces) / sizeof(pieces[0]))];
			size_t m = strlen(p);
			memcpy(out + n, p, m);
			n += m;
		}
	}
	if (rand() % 6 == 0) {   /* long fields */
		int k = rand() % 300;
		for (int i = 0; i < k && n + 2 < size; i++) out[n++] = 'A' + rand() % 26;
	}
	out[n] = '\0';
}

int
main(int argc, char **argv)
{
	struct lib A, F;
	load(&A, dlopen("/usr/lib/system/libquarantine.dylib", RTLD_NOW));
	load(&F, dlopen(argv[1], RTLD_NOW | RTLD_LOCAL));
	if (!F.alloc) { fprintf(stderr, "can't load %s\n", argv[1]); return 2; }

	/* Parse: structured labels plus random bytes. */
	for (unsigned i = 0; i < 20000; i++) {
		char label[1024];
		gen_label(label, sizeof(label), i);
		qf_t qa = A.alloc(), qb = F.alloc();
		int ra = A.init_data(qa, label, strlen(label)), rb = F.init_data(qb, label, strlen(label));
		EXPECT(ra == rb, "parse [%s]: rc %d vs %d", label, ra, rb);
		same_fields(&A, qa, &F, qb, label);   /* after failures too */
		A.free(qa); F.free(qb);
	}

	/* Serialize: random records through the setters. */
	srand(1);
	for (unsigned i = 0; i < 20000; i++) {
		qf_t qa = A.alloc(), qb = F.alloc();
		uint32_t fl = (uint32_t)rand() % 0x2400;
		uint64_t ts = ((uint64_t)rand() << 32 | (uint64_t)rand()) >> (rand() % 64);
		char id[300], md[80];
		size_t idn = (size_t)rand() % 270, mdn = (size_t)rand() % 70;
		for (size_t k = 0; k < idn; k++) id[k] = (char)(1 + rand() % 255);
		id[idn] = '\0';
		for (size_t k = 0; k < mdn; k++) md[k] = (char)(rand() % 256);
		EXPECT(A.sflags(qa, fl) == F.sflags(qb, fl), "set_flags %x", fl);
		A.sts(qa, ts); F.sts(qb, ts);
		EXPECT(A.sid(qa, id) == F.sid(qb, id), "set_identifier (%zu)", idn);
		EXPECT(A.smd(qa, md, mdn) == F.smd(qb, md, mdn), "set_metadata (%zu)", mdn);
		same_fields(&A, qa, &F, qb, "setters");
		A.free(qa); F.free(qb);
	}

	/* Files: what each library writes to disk, and reading it back. */
	const char *tmpl = "/private/tmp/finch-qtn-XXXXXX";
	for (unsigned i = 0; i < 200; i++) {
		char pa[64], pb[64];
		strcpy(pa, tmpl); strcpy(pb, tmpl);
		int fa = mkstemp(pa), fb = mkstemp(pb);
		qf_t qa = A.alloc(), qb = F.alloc();
		char label[1024];
		gen_label(label, sizeof(label), 100000 + i);
		if (A.init_data(qa, label, strlen(label)) != 0) { snprintf(label, sizeof(label), "q/%04x;%08x;agent%u;meta\\x3b%u", i % 0x2000, i * 7919, i, i); A.init_data(qa, label, strlen(label)); }
		F.init_data(qb, label, strlen(label));
		int ra = A.apply_fd(qa, fa), rb = F.apply_fd(qb, fb);
		EXPECT(ra == rb, "apply [%s]: rc %d/%d", label, ra, rb);
		/* Finch writes the record as given (Apple's goes through the kernel's
		 * quarantine policy, which restamps it): the attribute must be
		 * exactly Finch's own serialization. */
		char xb[4096] = "", own[4096];
		size_t ol = sizeof(own);
		ssize_t nb = fgetxattr(fb, "com.apple.quarantine", xb, sizeof(xb), 0, 0);
		F.to_data(qb, own, &ol);
		EXPECT(nb >= 0 && (size_t)nb == strlen(own + 2) && memcmp(xb, own + 2, (size_t)nb) == 0,
		    "apply [%s]: wrote [%.*s], expected [%s]", label, (int)nb, xb, own + 2);
		/* Reading what Apple's library applied: both libraries agree. */
		qf_t ra2 = A.alloc(), rb2 = F.alloc();
		EXPECT(A.init_fd(ra2, fa) == F.init_fd(rb2, fa), "init_with_fd rc");
		same_fields(&A, ra2, &F, rb2, "init_with_fd");
		qf_t na3 = A.alloc(), nb3 = F.alloc();
		int u = open("/dev/null", O_RDONLY);
		EXPECT(A.init_fd(na3, u) == F.init_fd(nb3, u), "init_with_fd on unquarantined file");
		close(u);
		close(fa); close(fb); unlink(pa); unlink(pb);
	}

	printf("%s: %d checks, %d differ\n", bad ? "FAILED" : "PASSED", checks, bad);
	return bad != 0;
}
