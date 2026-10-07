/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * bsm-compare: run the libbsm interfaces Finch adds to OpenBSM-21
 * (finch_compat.c) in Apple's library and in Finch's, and compare results,
 * errno and token bytes. Runs unprivileged: calls that need privilege are
 * compared on their failure.
 *
 *   bsm-compare /path/to/finch/libbsm.0.dylib
 */

#include <bsm/audit_session.h>
#include <bsm/libbsm.h>
#include <bsm/audit_kevents.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned checks, failures;

#define CHECK(cond, ...)                                                  \
	do {                                                              \
		checks++;                                                 \
		if (!(cond)) {                                            \
			failures++;                                       \
			if (failures <= 20) {                             \
				fprintf(stderr, "FAIL line %d: ", __LINE__); \
				fprintf(stderr, __VA_ARGS__);             \
				fputc('\n', stderr);                      \
			}                                                 \
		}                                                         \
	} while (0)

struct lib {
	void *h;
	uid_t (*to_auid)(audit_token_t);
	uid_t (*to_euid)(audit_token_t);
	gid_t (*to_egid)(audit_token_t);
	uid_t (*to_ruid)(audit_token_t);
	gid_t (*to_rgid)(audit_token_t);
	pid_t (*to_pid)(audit_token_t);
	au_asid_t (*to_asid)(audit_token_t);
	int (*to_pidversion)(audit_token_t);
	ssize_t (*sflagstostr)(uint64_t, size_t, char *);
	int (*strtosflags)(const char *, uint64_t *);
	token_t *(*to_identity)(uint32_t, const char *, u_char, const char *, u_char, uint8_t *,
	    uint16_t);
	token_t *(*to_cert)(char **);
	token_t *(*to_krb5)(char **);
	token_t *(*to_kevent)(void *);
	token_t *(*to_text)(const char *);
	int (*close_token)(token_t *, u_char *, size_t *);
	int (*fetch_tok)(tokenstr_t *, u_char *, int);
	void (*print_flags)(FILE *, tokenstr_t *, char *, int);
	int (*acsmask)(const char *, char *, size_t);
	int (*get_sflags_mask)(const char *, uint64_t *);
	int (*set_sflags_mask)(const char *, uint64_t);
	int (*get_sflags)(uint64_t *);
	int (*set_sflags)(uint64_t);
	int (*get_ctlmode)(void *, size_t);
	int (*get_expire)(void *, size_t);
	int (*tid_ex)(au_tid_addr_t *);
	int (*open)(void);
	int (*close_err)(int, int, short);
	int (*write_ok_ex)(short, token_t *, au_id_t, uid_t, gid_t, uid_t, gid_t, pid_t,
	    au_asid_t, au_tid_addr_t *);
	int (*write_fail_ex)(short, char *, int, au_id_t, uid_t, gid_t, uid_t, gid_t, pid_t,
	    au_asid_t, au_tid_addr_t *);
	int (*write_fail_na_ex)(short, char *, int, uid_t, gid_t, pid_t, au_tid_addr_t *);
	au_sdev_handle_t *(*sdev_open)(int);
	int (*sdev_close)(au_sdev_handle_t *);
	int (*sdev_fd)(au_sdev_handle_t *);
	int (*sdev_read)(au_sdev_handle_t *, int *, auditinfo_addr_t *);
};

static void *
sym(void *h, const char *name)
{
	void *p = dlsym(h, name);

	if (p == NULL) {
		fprintf(stderr, "missing %s\n", name);
		exit(2);
	}
	return p;
}

static void
load(struct lib *l, const char *path)
{
	if ((l->h = dlopen(path, RTLD_NOW | RTLD_LOCAL)) == NULL) {
		fprintf(stderr, "%s\n", dlerror());
		exit(2);
	}
#define L(field, name) l->field = sym(l->h, name)
	L(to_auid, "audit_token_to_auid");
	L(to_euid, "audit_token_to_euid");
	L(to_egid, "audit_token_to_egid");
	L(to_ruid, "audit_token_to_ruid");
	L(to_rgid, "audit_token_to_rgid");
	L(to_pid, "audit_token_to_pid");
	L(to_asid, "audit_token_to_asid");
	L(to_pidversion, "audit_token_to_pidversion");
	L(sflagstostr, "au_sflagstostr");
	L(strtosflags, "au_strtosflags");
	L(to_identity, "au_to_identity");
	L(to_cert, "au_to_certificate_hash");
	L(to_krb5, "au_to_krb5_principal");
	L(to_kevent, "au_to_kevent");
	L(to_text, "au_to_text");
	L(close_token, "au_close_token");
	L(fetch_tok, "au_fetch_tok");
	L(print_flags, "au_print_flags_tok");
	L(acsmask, "getacsflagsmask");
	L(get_sflags_mask, "audit_get_sflags_mask");
	L(set_sflags_mask, "audit_set_sflags_mask");
	L(get_sflags, "audit_get_sflags");
	L(set_sflags, "audit_set_sflags");
	L(get_ctlmode, "audit_get_ctlmode");
	L(get_expire, "audit_get_expire_after");
	L(tid_ex, "audit_set_terminal_id_ex");
	L(open, "au_open");
	L(close_err, "au_close_with_errors");
	L(write_ok_ex, "audit_write_success_ex");
	L(write_fail_ex, "audit_write_failure_ex");
	L(write_fail_na_ex, "audit_write_failure_na_ex");
	L(sdev_open, "au_sdev_open");
	L(sdev_close, "au_sdev_close");
	L(sdev_fd, "au_sdev_fd");
	L(sdev_read, "au_sdev_read_aia");
#undef L
}

/* A token's bytes, via each library's own au_close_token(). */
static size_t
bytes(struct lib *l, token_t *t, u_char *out, size_t cap)
{
	size_t len = cap;

	if (t == NULL)
		return 0;
	if (l->close_token(t, out, &len) != 0)
		return (size_t)-1;
	return len;
}

static void
compare_tokens(struct lib *a, struct lib *f, token_t *ta, token_t *tf, const char *what)
{
	u_char ba[4096], bf[4096];
	size_t na = bytes(a, ta, ba, sizeof(ba)), nf = bytes(f, tf, bf, sizeof(bf));

	CHECK((ta == NULL) == (tf == NULL), "%s: NULL differs", what);
	CHECK(na == nf && memcmp(ba, bf, na) == 0, "%s: token bytes differ (%zu vs %zu)", what, na, nf);
}

int
main(int argc, char **argv)
{
	struct lib apple, finch;

	if (argc != 2) {
		fprintf(stderr, "usage: bsm-compare finch-libbsm.0.dylib\n");
		return 2;
	}
	load(&apple, "/usr/lib/libbsm.0.dylib");
	load(&finch, argv[1]);

	/* audit_token_to_*() */
	srandom(7);
	for (int i = 0; i < 200; i++) {
		audit_token_t t;

		for (int k = 0; k < 8; k++)
			t.val[k] = (unsigned)random() ^ ((unsigned)random() << 16);
		CHECK(apple.to_auid(t) == finch.to_auid(t) && apple.to_euid(t) == finch.to_euid(t) &&
		    apple.to_egid(t) == finch.to_egid(t) && apple.to_ruid(t) == finch.to_ruid(t) &&
		    apple.to_rgid(t) == finch.to_rgid(t) && apple.to_pid(t) == finch.to_pid(t) &&
		    apple.to_asid(t) == finch.to_asid(t) &&
		    apple.to_pidversion(t) == finch.to_pidversion(t), "audit_token_to_* %d", i);
	}

	/* au_sflagstostr(): every flag combination (and stray bits) at every size. */
	static const uint64_t bits[] = { 0x1, 0x10, 0x20, 0x1000, 0x2000, 0x4000, 0x2, 0x8000 };
	for (unsigned m = 0; m < 256; m++) {
		uint64_t flags = 0;

		for (int b = 0; b < 8; b++)
			if (m & (1u << b))
				flags |= bits[b];
		for (size_t size = 0; size <= 120; size++) {
			char ba[128], bf[128];
			ssize_t ra, rf;

			memset(ba, 'x', sizeof(ba));
			memset(bf, 'x', sizeof(bf));
			ra = apple.sflagstostr(flags, size, ba);
			rf = finch.sflagstostr(flags, size, bf);
			CHECK(ra == rf && memcmp(ba, bf, sizeof(ba)) == 0,
			    "au_sflagstostr(%#llx, %zu): %zd vs %zd", (unsigned long long)flags, size, ra, rf);
		}
	}

	/* au_strtosflags() */
	static const char *inputs[] = { "", ",", "is_initial", "has_tty,is_remote",
		"has_graphic_access,has_console_access,has_authenticated", "is_initial,,has_tty",
		"has_tty,has_tty", "bogus", "has_tty,bogus", "HAS_TTY", " has_tty", "is_initial,",
		"is_initial,has_graphic_access,has_tty,is_remote,has_console_access,has_authenticated" };
	for (size_t i = 0; i < sizeof(inputs) / sizeof(inputs[0]); i++) {
		uint64_t fa = 99, ff = 99;
		int ra, rf, ea, ef;

		errno = 0;
		ra = apple.strtosflags(inputs[i], &fa);
		ea = errno;
		errno = 0;
		rf = finch.strtosflags(inputs[i], &ff);
		ef = errno;
		CHECK(ra == rf && fa == ff && (ra == 0 || ea == ef), "au_strtosflags(\"%s\")", inputs[i]);
	}

	/* Tokens */
	uint8_t cdhash[20];
	for (int i = 0; i < 20; i++)
		cdhash[i] = (uint8_t)(i * 13 + 1);
	struct {
		uint32_t type;
		const char *sid;
		u_char st;
		const char *tid;
		u_char tt;
		uint16_t clen;
	} ids[] = {
		{ 1, "com.example.tool", 0, "ABCDE12345", 0, 20 },
		{ 0x7fffffff, "x", 1, "", 1, 0 },
		{ 2, NULL, 0, NULL, 0, 20 },
		{ 3, "org.finch.a.very.long.signing.identifier.that.keeps.going", 1, NULL, 0, 7 },
	};
	for (size_t i = 0; i < sizeof(ids) / sizeof(ids[0]); i++)
		compare_tokens(&apple, &finch,
		    apple.to_identity(ids[i].type, ids[i].sid, ids[i].st, ids[i].tid, ids[i].tt, cdhash,
		        ids[i].clen),
		    finch.to_identity(ids[i].type, ids[i].sid, ids[i].st, ids[i].tid, ids[i].tt, cdhash,
		        ids[i].clen),
		    "au_to_identity");
	char *none[] = { NULL }, *one[] = { "deadbeef", NULL },
	     *three[] = { "aa", "", "a much longer hash string", NULL };
	char **arrays[] = { none, one, three };
	for (size_t i = 0; i < 3; i++) {
		compare_tokens(&apple, &finch, apple.to_cert(arrays[i]), finch.to_cert(arrays[i]),
		    "au_to_certificate_hash");
		compare_tokens(&apple, &finch, apple.to_krb5(arrays[i]), finch.to_krb5(arrays[i]),
		    "au_to_krb5_principal");
	}
	CHECK(apple.to_kevent(NULL) == NULL && finch.to_kevent(NULL) == NULL, "au_to_kevent");

	/* errno contracts */
	char sbuf[64];
	uint64_t mask;
	int ra, rf, ea, ef;
#define SAME(call_a, call_f, what)                                             \
	do {                                                                   \
		errno = 0;                                                     \
		ra = (call_a);                                                 \
		ea = errno;                                                    \
		errno = 0;                                                     \
		rf = (call_f);                                                 \
		ef = errno;                                                    \
		CHECK(ra == rf && (ra == 0 || ea == ef), "%s: %d/%d errno %d/%d", what, ra, rf, ea, ef); \
	} while (0)
	SAME(apple.acsmask("lo", sbuf, sizeof(sbuf)), finch.acsmask("lo", sbuf, sizeof(sbuf)),
	    "getacsflagsmask");
	SAME(apple.get_sflags_mask("x", &mask), finch.get_sflags_mask("x", &mask),
	    "audit_get_sflags_mask");
	SAME(apple.set_sflags_mask("x", 1), finch.set_sflags_mask("x", 1), "audit_set_sflags_mask");
	uint64_t sa = 0, sf = 0;
	SAME(apple.get_sflags(&sa), finch.get_sflags(&sf), "audit_get_sflags");
	CHECK(sa == sf, "audit_get_sflags value %#llx vs %#llx", (unsigned long long)sa,
	    (unsigned long long)sf);
	SAME(apple.set_sflags(sa), finch.set_sflags(sf), "audit_set_sflags (same flags)");
	char mode_a[64], mode_f[64];
	for (size_t sz = 0; sz < 40; sz++) {
		SAME(apple.get_ctlmode(mode_a, sz), finch.get_ctlmode(mode_f, sz), "audit_get_ctlmode");
		SAME(apple.get_expire(mode_a, sz), finch.get_expire(mode_f, sz), "audit_get_expire_after");
	}

	/* audit_set_terminal_id_ex() */
	au_tid_addr_t tida, tidf;
	memset(&tida, 0xa5, sizeof(tida));
	memset(&tidf, 0xa5, sizeof(tidf));
	CHECK(apple.tid_ex(NULL) == finch.tid_ex(NULL), "audit_set_terminal_id_ex(NULL)");
	ra = apple.tid_ex(&tida);
	rf = finch.tid_ex(&tidf);
	CHECK(ra == rf && memcmp(&tida, &tidf, sizeof(tida)) == 0, "audit_set_terminal_id_ex fill");

	/* au_close_with_errors(): discard, bad descriptor, and a write (fails unprivileged). */
	int da = apple.open(), df = finch.open();
	SAME(apple.close_err(da, AU_TO_NO_WRITE, 0), finch.close_err(df, AU_TO_NO_WRITE, 0),
	    "au_close_with_errors discard");
	SAME(apple.close_err(da, AU_TO_WRITE, 0), finch.close_err(df, AU_TO_WRITE, 0),
	    "au_close_with_errors closed descriptor");
	da = apple.open();
	df = finch.open();
	SAME(apple.close_err(da, AU_TO_WRITE, AUE_AUDIT), finch.close_err(df, AU_TO_WRITE, AUE_AUDIT),
	    "au_close_with_errors write");

	/* au_write() wrappers (audit(2) fails unprivileged; compare how). */
	au_tid_addr_t tid = { 0 };
	SAME(apple.write_ok_ex(AUE_AUDIT, apple.to_text("ok"), 501, 501, 20, 501, 20, 1, 1, &tid),
	    finch.write_ok_ex(AUE_AUDIT, finch.to_text("ok"), 501, 501, 20, 501, 20, 1, 1, &tid),
	    "audit_write_success_ex");
	SAME(apple.write_fail_ex(AUE_AUDIT, "bad", 5, 501, 501, 20, 501, 20, 1, 1, &tid),
	    finch.write_fail_ex(AUE_AUDIT, "bad", 5, 501, 501, 20, 501, 20, 1, 1, &tid),
	    "audit_write_failure_ex");
	SAME(apple.write_fail_na_ex(AUE_AUDIT, "bad", 5, 501, 20, 1, &tid),
	    finch.write_fail_na_ex(AUE_AUDIT, "bad", 5, 501, 20, 1, &tid),
	    "audit_write_failure_na_ex");

	/* au_print_flags_tok(): a text token in raw, short and XML forms. */
	for (int oflags = 0; oflags < 8; oflags++) {
		u_char raw[256];
		size_t n = bytes(&apple, apple.to_text("hello, audit"), raw, sizeof(raw));
		tokenstr_t tok;
		char *outa = NULL, *outf = NULL;
		size_t la = 0, lf = 0;
		FILE *fa = open_memstream(&outa, &la), *ff = open_memstream(&outf, &lf);

		memset(&tok, 0, sizeof(tok));
		apple.fetch_tok(&tok, raw, (int)n);
		apple.print_flags(fa, &tok, ",", oflags);
		memset(&tok, 0, sizeof(tok));
		finch.fetch_tok(&tok, raw, (int)n);
		finch.print_flags(ff, &tok, ",", oflags);
		fclose(fa);
		fclose(ff);
		CHECK(la == lf && memcmp(outa, outf, la) == 0, "au_print_flags_tok(%d): \"%s\" vs \"%s\"",
		    oflags, outa, outf);
		free(outa);
		free(outf);
	}

	/* The session device: open (and a non-blocking read) as the user may. */
	for (int fl = 0; fl < 2; fl++) {
		int flags = fl ? AU_SDEVF_NONBLOCK : 0;
		au_sdev_handle_t *ha, *hf;

		errno = 0;
		ha = apple.sdev_open(flags);
		ea = errno;
		errno = 0;
		hf = finch.sdev_open(flags);
		ef = errno;
		CHECK((ha == NULL) == (hf == NULL) && (ha != NULL || ea == ef), "au_sdev_open(%d)", flags);
		if (ha != NULL && hf != NULL && fl) {
			int eva = -1, evf = -1;
			auditinfo_addr_t aa, af;

			CHECK((apple.sdev_fd(ha) >= 0) == (finch.sdev_fd(hf) >= 0), "au_sdev_fd");
			SAME(apple.sdev_read(ha, &eva, &aa), finch.sdev_read(hf, &evf, &af),
			    "au_sdev_read_aia (no events)");
		}
		if (ha != NULL)
			apple.sdev_close(ha);
		if (hf != NULL)
			finch.sdev_close(hf);
	}

	printf("libbsm: %u checks, %u failures\n", checks, failures);
	return failures != 0;
}
