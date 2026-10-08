/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-compression-test [other-libcompression.dylib]
 *
 * Round-trips every algorithm through libcompression's buffer and stream
 * APIs (streams fed in small, uneven pieces), over inputs from empty to
 * several MiB. Given another libcompression, it also checks each library
 * decodes what the other encodes: on the host, Finch's against Apple's.
 */
#include <compression.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct lib {
	const char *name;
	size_t (*enc)(uint8_t *, size_t, const uint8_t *, size_t, void *, compression_algorithm);
	size_t (*dec)(uint8_t *, size_t, const uint8_t *, size_t, void *, compression_algorithm);
	compression_status (*init)(compression_stream *, compression_stream_operation, compression_algorithm);
	compression_status (*process)(compression_stream *, int);
	compression_status (*destroy)(compression_stream *);
};

static int failures;

#define CHECK(c, ...) do { if (!(c)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

/* Stream src through lib in pieces of `in` bytes into a dst `out` at a time.
 * Returns the output length, or (size_t)-1. */
static size_t
stream(const struct lib *l, compression_stream_operation op, compression_algorithm alg,
    const uint8_t *src, size_t n, uint8_t *dst, size_t cap, size_t in, size_t out)
{
	compression_stream s;
	if (l->init(&s, op, alg) != COMPRESSION_STATUS_OK)
		return (size_t)-1;
	size_t used = 0, made = 0;
	for (int spins = 0; spins < 50000000; spins++) {
		size_t give = n - used < in ? n - used : in;
		size_t room = cap - made < out ? cap - made : out;
		s.src_ptr = src + used;
		s.src_size = give;
		s.dst_ptr = dst + made;
		s.dst_size = room;
		compression_status r = l->process(&s, used + give == n ? COMPRESSION_STREAM_FINALIZE : 0);
		used += give - s.src_size;
		made += room - s.dst_size;
		if (r == COMPRESSION_STATUS_END) {
			l->destroy(&s);
			return made;
		}
		if (r != COMPRESSION_STATUS_OK || (room == 0 && made == cap))
			break;
	}
	l->destroy(&s);
	return (size_t)-1;
}

static const struct { compression_algorithm alg; const char *name; int stream; } algs[] = {
	{ COMPRESSION_LZ4, "lz4", 1 }, { COMPRESSION_LZ4_RAW, "lz4_raw", 0 },
	{ COMPRESSION_ZLIB, "zlib", 1 }, { COMPRESSION_LZMA, "lzma", 1 },
	{ COMPRESSION_LZFSE, "lzfse", 1 }, { COMPRESSION_BROTLI, "brotli", 1 },
};

static void
test(const struct lib *a, const struct lib *b, const char *what, const uint8_t *src, size_t n)
{
	size_t cap = n + n / 2 + 65536;
	uint8_t *enc = malloc(cap), *dec = malloc(n + 1);
	for (size_t i = 0; i < sizeof(algs) / sizeof(algs[0]); i++) {
		compression_algorithm alg = algs[i].alg;
		const char *an = algs[i].name;
		/* a encodes, b decodes: buffers */
		size_t e = a->enc(enc, cap, src, n, NULL, alg);
		CHECK(e > 0 || (n == 0 && alg == COMPRESSION_LZ4_RAW), "%s %s: %s encode_buffer", an, what, a->name);
		size_t d = b->dec(dec, n + 1, enc, e, NULL, alg);
		CHECK(d == n && !memcmp(dec, src, n), "%s %s: %s decodes %s's buffer (%zu of %zu)",
		    an, what, b->name, a->name, d, n);
		if (n > 1000) {
			/* As Apple's library does: what fits, except for LZMA and Brotli (0). */
			d = b->dec(dec, 1000, enc, e, NULL, alg);
			int none = alg == COMPRESSION_LZMA || alg == COMPRESSION_BROTLI;
			CHECK(none ? d == 0 : d == 1000 && !memcmp(dec, src, 1000),
			    "%s %s: %s partial decode (%zu)", an, what, b->name, d);
		}
		if (!algs[i].stream)
			continue;
		/* a encodes as a stream, b decodes as a stream, both in odd pieces */
		size_t se = stream(a, COMPRESSION_STREAM_ENCODE, alg, src, n, enc, cap, 4093, 777);
		CHECK(se != (size_t)-1, "%s %s: %s stream encode", an, what, a->name);
		if (se == (size_t)-1)
			continue;
		size_t sd = stream(b, COMPRESSION_STREAM_DECODE, alg, enc, se, dec, n + 1, 1031, 5003);
		CHECK(sd == n && !memcmp(dec, src, n), "%s %s: %s stream-decodes %s's stream (%zu of %zu)",
		    an, what, b->name, a->name, sd, n);
		d = b->dec(dec, n + 1, enc, se, NULL, alg);
		CHECK(d == n && !memcmp(dec, src, n), "%s %s: %s buffer-decodes %s's stream", an, what, b->name, a->name);
	}
	free(enc);
	free(dec);
}

static struct lib
load(const char *path)
{
	struct lib l = { .name = path };
	void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (!h) {
		printf("%s\n", dlerror());
		exit(2);
	}
	l.enc = dlsym(h, "compression_encode_buffer");
	l.dec = dlsym(h, "compression_decode_buffer");
	l.init = dlsym(h, "compression_stream_init");
	l.process = dlsym(h, "compression_stream_process");
	l.destroy = dlsym(h, "compression_stream_destroy");
	Dl_info a, b;
	if (!l.enc || !dladdr((void *)l.enc, &a) || !dladdr((void *)compression_encode_buffer, &b) ||
	    a.dli_fbase == b.dli_fbase) {
		printf("%s: not loaded as a second library\n", path);
		exit(2);
	}
	return l;
}

int
main(int argc, char **argv)
{
	struct lib self = { "this", compression_encode_buffer, compression_decode_buffer,
	    compression_stream_init, compression_stream_process, compression_stream_destroy };
	struct lib other = argc > 1 ? load(argv[1]) : self;

	size_t big = 5 << 20;
	uint8_t *buf = malloc(big);
	struct { const char *what; size_t n; } inputs[] = {
		{ "empty", 0 }, { "text", 0 }, { "patterned 1MiB", 1 << 20 },
		{ "noise 3MiB", 3 << 20 }, { "repetitive 5MiB", big },
	};
	const char *text = "Finch is an open-source OS for Apple Silicon built on Darwin/XNU.\n";
	for (size_t t = 0; t < sizeof(inputs) / sizeof(inputs[0]); t++) {
		size_t n = inputs[t].n;
		uint64_t x = 0x9E3779B97F4A7C15ull;
		for (size_t i = 0; i < n; i++) {
			if (t == 2)
				buf[i] = (uint8_t)((i * 7) ^ (i >> 9));
			else if (t == 3)
				buf[i] = (uint8_t)((x ^= x << 13, x ^= x >> 7, x ^= x << 17) >> 32);
			else
				buf[i] = (uint8_t)text[(i / 3) % 66];
		}
		if (t == 1) {
			n = strlen(text);
			memcpy(buf, text, n);
		}
		test(&self, &self, inputs[t].what, buf, n);
		if (argc > 1) {
			test(&self, &other, inputs[t].what, buf, n);
			test(&other, &self, inputs[t].what, buf, n);
		}
		printf("%s: done\n", inputs[t].what);
	}
	uint8_t tiny[16];
	CHECK(compression_encode_buffer(tiny, sizeof(tiny), buf, big, NULL, COMPRESSION_LZFSE) == 0,
	    "lzfse: encode into too small a buffer returns 0");
	if (failures)
		printf("FAILED: %d\n", failures);
	else
		printf("PASSED: libcompression%s\n", argc > 1 ? " (cross-checked)" : "");
	return failures != 0;
}
