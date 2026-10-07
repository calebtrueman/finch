/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Decode clang's compact log arguments. Layout and rendering are checked
 * against the host; no closed-source implementation is used. */
#include "format.h"
#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <ctype.h>
extern bool finch_log_object_is_public(void *);
extern char *finch_log_describe_object(void *);
#define MAX_MESSAGE (1024 * 1024)
struct text {
	char *p;
	size_t n, cap;
	int failed;
};
static void append(struct text *t, const char *s, size_t n)
{
	if (t->failed)
		return;
	if (n > MAX_MESSAGE - t->n) {
		t->failed = 1;
		return;
	}
	if (t->n + n + 1 > t->cap) {
		size_t cap = (t->n + n + 1) * 2;
		char *p = realloc(t->p, cap);
		if (!p) {
			t->failed = 1;
			return;
		}
		t->p = p;
		t->cap = cap;
	}
	memcpy(t->p + t->n, s, n);
	t->n += n;
	t->p[t->n] = 0;
}
static void string(struct text *t, const char *s)
{
	append(t, s, strlen(s));
}
static void print(struct text *t, const char *f, ...)
{
	va_list ap, copy;
	va_start(ap, f);
	va_copy(copy, ap);
	int n = vsnprintf(NULL, 0, f, copy);
	va_end(copy);
	if (n < 0 || n > MAX_MESSAGE) {
		t->failed = 1;
		va_end(ap);
		return;
	}
	char *p = malloc((size_t)n + 1);
	if (!p) {
		t->failed = 1;
		va_end(ap);
		return;
	}
	vsnprintf(p, (size_t)n + 1, f, ap);
	va_end(ap);
	append(t, p, (size_t)n);
	free(p);
}
struct record {
	uint8_t type, flags, size;
	uint64_t value;
	const uint8_t *bytes;
};
struct records {
	const uint8_t *p, *end;
	unsigned left;
};
static bool next(struct records *r, struct record *v)
{
	if (!r->left || r->end - r->p < 2)
		return false;
	size_t n = r->p[1];
	if ((size_t)(r->end - r->p) < n + 2)
		return false;
	*v = (struct record){r->p[0] >> 4, r->p[0] & 15, (uint8_t)n, 0, r->p + 2};
	memcpy(&v->value, v->bytes, n < 8 ? n : 8);
	r->p += n + 2;
	r->left--;
	return true;
}
static bool argument(struct records *r, struct record *v)
{
	do {
		if (!next(r, v))
			return false;
	} while (v->type == 7);
	return true;
}
static int64_t signed_value(struct record *v)
{
	switch (v->size) {
	case 1:
		return (int8_t)v->value;
	case 2:
		return (int16_t)v->value;
	case 4:
		return (int32_t)v->value;
	default:
		return (int64_t)v->value;
	}
}
static bool annotation(const char *s, const char *key)
{
	size_t n = strlen(key);
	for (const char *p = s; *p;) {
		while (*p == ' ' || *p == ',')
			p++;
		if (!strncmp(p, key, n) && (p[n] == 0 || p[n] == ',' || p[n] == ' '))
			return true;
		while (*p && *p != ',')
			p++;
	}
	return false;
}
static void bytes_value(struct text *t, const uint8_t *p, int n, bool uuid)
{
	if (!p) {
		string(t, "(null)");
		return;
	}
	if (n < 0)
		n = 0;
	if (n > 65535)
		n = 65535;
	if (uuid && n == 16) {
		for (int i = 0; i < 16; i++) {
			if (i == 4 || i == 6 || i == 8 || i == 10)
				string(t, "-");
			print(t, "%02X", p[i]);
		}
		return;
	}
	string(t, "'");
	for (int i = 0; i < n; i++) {
		if (i)
			string(t, " ");
		print(t, "%02x", p[i]);
	}
	string(t, "'");
}
static void scaled(struct text *t, uint64_t value, bool iec, bool rate)
{
	static const char *decimal[] = {"B", "kB", "MB", "GB", "TB", "PB", "EB"};
	static const char *binary[] = {"B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"};
	static const char *bitrates[] = {"bps", "kbps", "Mbps", "Gbps", "Tbps"};
	static const char *ibitrates[] = {"bps", "Kibps", "Mibps", "Gibps", "Tibps"};
	const char *const *units = rate ? (iec ? ibitrates : bitrates) : (iec ? binary : decimal);
	unsigned base = iec ? 1024 : 1000, index = 0, fraction = 0, max = rate ? 4 : 6;
	while (value >= 1000 && index < max) {
		fraction = (unsigned)(value % base);
		value /= base;
		index++;
	}
	fraction = (fraction * 100 + base / 2) / base;
	if (fraction == 100) {
		fraction = 0;
		value++;
	}
	if (!index || !fraction || value > 99)
		print(t, "%llu %s", (unsigned long long)value, units[index]);
	else if (value > 9 || fraction % 10 == 0)
		print(t, "%llu.%u %s", (unsigned long long)value, fraction / 10, units[index]);
	else
		print(t, "%llu.%02u %s", (unsigned long long)value, fraction, units[index]);
}
static char *compose(const char *format, const uint8_t *data, size_t size, int saved_errno,
    char *buffer, size_t capacity, bool wire_objects, bool trim_tail)
{
	if (!format)
		format = "";
	struct text out = {0};
	struct records r = {0};
	if (data && size >= 2)
		r = (struct records){data + 2, data + size, data[1]};
	const char *f = format;
	while (*f) {
		if (*f != '%') {
			const char *s = f;
			while (*f && *f != '%')
				f++;
			append(&out, s, (size_t)(f - s));
			continue;
		}
		const char *start = f++;
		if (*f == '%') {
			string(&out, "%");
			f++;
			continue;
		}
		char meta[160] = {0};
		if (*f == '{') {
			f++;
			const char *s = f;
			while (*f && *f != '}')
				f++;
			size_t n = (size_t)(f - s);
			if (n >= sizeof(meta))
				n = sizeof(meta) - 1;
			memcpy(meta, s, n);
			if (*f == '}')
				f++;
		}
		char flags[16] = {0};
		size_t fi = 0;
		while (*f && strchr("-+ #0'", *f)) {
			if (fi < sizeof(flags) - 1)
				flags[fi++] = *f;
			f++;
		}
		int width = 0, precision = -1;
		struct record v = {0};
		if (*f == '*') {
			f++;
			if (!argument(&r, &v))
				goto missing;
			width = (int)signed_value(&v);
		} else
			while (isdigit((unsigned char)*f)) {
				if (width < MAX_MESSAGE)
					width = width * 10 + *f - '0';
				f++;
			}
		if (*f == '.') {
			f++;
			precision = 0;
			if (*f == '*') {
				f++;
				if (!argument(&r, &v))
					goto missing;
				precision = (int)signed_value(&v);
			} else
				while (isdigit((unsigned char)*f)) {
					if (precision < MAX_MESSAGE)
						precision = precision * 10 + *f - '0';
					f++;
				}
		}
		char length[3] = {0};
		if (*f && strchr("hljztLq", *f)) {
			length[0] = *f++;
			if ((*f == 'h' && length[0] == 'h') || (*f == 'l' && length[0] == 'l'))
				length[1] = *f++;
		}
		char type = *f;
		if (*f)
			f++;
		if (!argument(&r, &v))
			goto missing;
		if (v.type == 1) {
			precision = (int)signed_value(&v);
			if (!argument(&r, &v))
				goto missing;
		}
		if ((v.flags & 1) || annotation(meta, "private") ||
		    (type == 'P' && !(v.flags & 2))) {
			string(&out, "<private>");
			continue;
		}
		if (width > MAX_MESSAGE)
			width = MAX_MESSAGE;
		if (width < -MAX_MESSAGE)
			width = -MAX_MESSAGE;
		if (precision > MAX_MESSAGE)
			precision = MAX_MESSAGE;
		if (annotation(meta, "bytes") || annotation(meta, "iec-bytes") ||
		    annotation(meta, "bitrate") || annotation(meta, "iec-bitrate")) {
			scaled(&out, v.value,
			    annotation(meta, "iec-bytes") || annotation(meta, "iec-bitrate"),
			    annotation(meta, "bitrate") || annotation(meta, "iec-bitrate"));
			continue;
		}
		if (annotation(meta, "bool") || annotation(meta, "BOOL")) {
			string(&out,
			    annotation(meta, "BOOL") ? (v.value ? "YES" : "NO")
			                             : (v.value ? "true" : "false"));
			continue;
		}
		if (annotation(meta, "errno")) {
			int e = (int)v.value;
			print(&out, "[%d: %s]", e, strerror(e));
			continue;
		}
		if (annotation(meta, "time_t")) {
			time_t tm = (time_t)signed_value(&v);
			struct tm local;
			char s[80];
			if (localtime_r(&tm, &local) &&
			    strftime(s, sizeof(s), "%Y-%m-%d %H:%M:%S%z", &local))
				string(&out, s);
			continue;
		}
		if (annotation(meta, "network:in_addr")) {
			struct in_addr addr = {(uint32_t)v.value};
			char s[INET_ADDRSTRLEN];
			if (inet_ntop(AF_INET, &addr, s, sizeof(s)))
				string(&out, s);
			continue;
		}
		if (type == '@' && wire_objects) {
			string(&out, v.value ? (const char *)(uintptr_t)v.value : "(null)");
			continue;
		}
		if (type == '@') {
			void *object = (void *)(uintptr_t)v.value;
			if (!(v.flags & 2) && !finch_log_object_is_public(object))
				string(&out, "<private>");
			else {
				char *description = finch_log_describe_object(object);
				if (description) {
					string(&out, description);
					free(description);
				}
			}
			continue;
		}
		if (type == 'P') {
			bytes_value(&out, (const void *)(uintptr_t)v.value, precision,
			    annotation(meta, "uuid_t"));
			continue;
		}
		if (type == 'm') {
			string(&out, strerror(v.type == 6 ? saved_errno : (int)v.value));
			continue;
		}
		if (type == 's' && length[0]) {
			print(&out, "<decode: mismatch for [%.*s] got [STRING sz:2]>",
			    (int)(f - start), start);
			continue;
		}
		char spec[80];
		char wid[24] = {0}, prec[24] = {0};
		if (width)
			snprintf(wid, sizeof(wid), "%d", width);
		if (precision >= 0)
			snprintf(prec, sizeof(prec), ".%d", precision);
		if (strchr("diouxX", type)) {
			snprintf(spec, sizeof(spec), "%%%s%s%sll%c", flags, wid, prec, type);
			if (type == 'd' || type == 'i') {
				int64_t sv = signed_value(&v);
				if (length[0] == 'h')
					sv = length[1] ? (int8_t)sv : (int16_t)sv;
				print(&out, spec, (long long)sv);
			} else {
				uint64_t uv = v.value;
				if (length[0] == 'h')
					uv = length[1] ? (uint8_t)uv : (uint16_t)uv;
				print(&out, spec, (unsigned long long)uv);
			}
			continue;
		}
		snprintf(spec, sizeof(spec), "%%%s%s%s%c", flags, wid, prec, type);
		if (strchr("fFeEgGaA", type)) {
			double d = 0;
			memcpy(&d, &v.value, 8);
			print(&out, spec, d);
		} else if (type == 's')
			print(&out, spec, (const char *)(uintptr_t)v.value);
		else if (type == 'c')
			print(&out, spec, (int)v.value);
		else if (type == 'p')
			print(&out, spec, (void *)(uintptr_t)v.value);
		else
			append(&out, start, (size_t)(f - start));
		continue;
	missing:
		string(&out, "<decode: missing data>");
		break;
	}
	if (out.failed) {
		free(out.p);
		return NULL;
	}
	if (!out.p)
		out.p = strdup("");
	size_t untrimmed = out.n;
	while (trim_tail && out.n && isspace((unsigned char)out.p[out.n - 1]))
		out.p[--out.n] = 0;
	if (buffer && untrimmed < capacity) {
		memcpy(buffer, out.p, out.n + 1);
		free(out.p);
		return buffer;
	}
	return out.p;
}

char *finch_log_compose(const char *f, const uint8_t *d, size_t n, int e, char *b, size_t cap)
{
	return compose(f, d, n, e, b, cap, false, true);
}

/* Wire records replace strings and byte pointers with (offset,length) pairs.
 * Private values leave a redacted marker when no private-data capture is on. */
int finch_log_flatten(const uint8_t *data, size_t size, int saved_errno, struct finch_log_wire *out)
{
	if (!data || size < 2)
		return -1;
	struct records r = {data + 2, data + size, data[1]};
	struct text records = {0}, payload = {0};
	uint8_t hdr[2] = {(uint8_t)(data[0] ? 0x20 : 0), 0};
	append(&records, (const char *)hdr, 2);
	struct record v;
	int count = -1;
	while (argument(&r, &v)) {
		uint8_t head[2] = {(uint8_t)(v.type << 4 | v.flags), v.size};
		uint64_t value = v.value;
		if (v.type == 1) {
			count = (int)(uint32_t)value;
			if (count < 0)
				count = 0;
			head[0] = 0x12;
			value = (uint32_t)count;
		}
		if (v.type == 6) {
			head[0] = 0;
			head[1] = 4;
			value = (uint32_t)saved_errno;
		}
		if (v.type >= 2 && v.type <= 5) {
			char *description = NULL;
			const char *p = (const void *)(uintptr_t)value;
			if (v.type == 4 || v.type == 5) {
				if (!(v.flags & 2) && !finch_log_object_is_public((void *)p))
					v.flags |= 1;
				description = finch_log_describe_object((void *)p);
				p = description;
				head[0] = (uint8_t)(v.type << 4 | v.flags);
				v.type = 2;
			}
			size_t n = 0;
			bool hidden = (v.flags & 1) || (v.type == 3 && !(v.flags & 2));
			head[1] = 4;
			if (hidden) {
				head[0] |= 1;
				value = 0;
			} else {
				if (p) {
					if (v.type == 2)
						n = count >= 0 ? strnlen(p, (size_t)count) + 1
						               : strnlen(p, 65534) + 1;
					else if (count >= 0)
						n = (size_t)count;
				}
				if (n > 65535 - payload.n)
					n = 65535 - payload.n;
				value = (uint32_t)payload.n | ((uint32_t)n << 16);
				if (n && v.type == 2) {
					append(&payload, p, n - 1);
					append(&payload, "", 1);
				} else if (n)
					append(&payload, p, n);
			}
			free(description);
			count = -1;
		} else if ((v.flags & 1) && v.type == 0) {
			head[1] = 4;
			value = UINT32_C(0x80000000);
		}
		if (head[0] & 1)
			records.p[0] |= 1;
		if ((head[0] >> 4) >= 2 && (head[0] >> 4) <= 5)
			records.p[0] |= 2;
		append(&records, (const char *)head, 2);
		append(&records, (const char *)&value, head[1] <= 8 ? head[1] : 8);
		records.p[1]++;
	}
	if (records.failed || payload.failed) {
		free(records.p);
		free(payload.p);
		return -1;
	}
	append(&records, payload.p, payload.n);
	free(payload.p);
	out->public_data = (void *)records.p;
	out->public_size = records.n;
	return records.failed ? -1 : 0;
}
char *finch_log_compose_wire(const char *format, const uint8_t *data, size_t size,
    const uint8_t *private_data, size_t private_size)
{
	if (!data || size < 2)
		return strdup(format ? format : "");
	struct records scan = {data + 2, data + size, data[1]};
	struct record v;
	while (next(&scan, &v)) {
	}
	const uint8_t *values = scan.p;
	size_t value_size = (size_t)(data + size - values);
	struct records r = {data + 2, data + size, data[1]};
	struct text converted = {0};
	uint8_t hdr[2] = {data[0], 0};
	append(&converted, (void *)hdr, 2);
	while (next(&r, &v)) {
		uint8_t head[2] = {(uint8_t)(v.type << 4 | v.flags), v.size};
		uint64_t value = v.value;
		if (v.type >= 2 && v.type <= 5 && v.size == 4) {
			size_t off = value & 65535, n = (value >> 16) & 65535;
			const uint8_t *base = v.flags & 1 ? private_data : values;
			size_t bound = v.flags & 1 ? private_size : value_size;
			value = n && base && off <= bound && n <= bound - off
			    ? (uintptr_t)(base + off)
			    : 0;
			head[1] = 8;
		}
		append(&converted, (void *)head, 2);
		append(&converted, (void *)&value, head[1] <= 8 ? head[1] : 8);
		converted.p[1]++;
	}
	char *out = compose(format, (void *)converted.p, converted.n, 0, NULL, 0, true, true);
	free(converted.p);
	return out;
}
static void add_argument(
    struct text *t, unsigned type, unsigned flags, unsigned size, uint64_t value)
{
	if ((unsigned char)t->p[1] == 255) {
		t->failed = 1;
		return;
	}
	uint8_t header[2] = {(uint8_t)(type << 4 | flags), (uint8_t)size};
	append(t, (void *)header, 2);
	append(t, (void *)&value, size);
	t->p[1]++;
	if (flags & 1)
		t->p[0] |= 1;
	if (type >= 2)
		t->p[0] |= 2;
}
uint8_t *finch_log_pack_arguments(const char *format, va_list input, size_t *size)
{
	struct text data = {0};
	append(&data, "\0\0", 2);
	va_list ap;
	va_copy(ap, input);
	const char *f = format;
	while (*f) {
		if (*f++ != '%')
			continue;
		if (*f == '%') {
			f++;
			continue;
		}
		unsigned flags = 0;
		if (*f == '{') {
			f++;
			const char *s = f;
			while (*f && *f != '}')
				f++;
			char meta[160] = {0};
			size_t n = (size_t)(f - s);
			if (n >= sizeof(meta))
				n = sizeof(meta) - 1;
			memcpy(meta, s, n);
			if (annotation(meta, "private"))
				flags = 1;
			else if (annotation(meta, "public"))
				flags = 2;
			if (*f)
				f++;
		}
		while (*f && strchr("-+ #0'", *f))
			f++;
		if (*f == '*') {
			int v = va_arg(ap, int);
			add_argument(&data, 0, 0, 4, (uint32_t)v);
			f++;
		} else
			while (isdigit((unsigned char)*f))
				f++;
		int precision = -1;
		bool dynamic = false;
		if (*f == '.') {
			f++;
			precision = 0;
			if (*f == '*') {
				dynamic = true;
				precision = va_arg(ap, int);
				f++;
			} else
				while (isdigit((unsigned char)*f)) {
					if (precision < 65536)
						precision = precision * 10 + *f - '0';
					f++;
				}
		}
		char length = *f, second = 0;
		if (*f && strchr("hljztLq", *f)) {
			f++;
			if ((*f == 'h' && length == 'h') || (*f == 'l' && length == 'l'))
				second = *f++;
		} else
			length = 0;
		char type = *f;
		if (!type)
			break;
		f++;
		if (precision >= 0 && (type == 's' || type == 'P' || type == '@'))
			add_argument(&data, 1, flags, 4, (uint32_t)precision);
		else if (dynamic)
			add_argument(&data, 0, 0, 4, (uint32_t)precision);
		if (type == 's' || type == 'P' || type == '@') {
			unsigned t = type == 's' ? 2 : type == 'P' ? 3 : 4;
			add_argument(&data, t, flags, 8, (uintptr_t)va_arg(ap, void *));
		} else if (type == 'p')
			add_argument(&data, 0, flags, 8, (uintptr_t)va_arg(ap, void *));
		else if (type == 'm')
			add_argument(&data, 6, flags, 0, 0);
		else if (strchr("fFeEgGaA", type)) {
			double v = va_arg(ap, double);
			uint64_t bits;
			memcpy(&bits, &v, 8);
			add_argument(&data, 0, flags, 8, bits);
		} else if (strchr("diouxXc", type)) {
			uint64_t value;
			unsigned bytes = 4;
			if (length == 'l' || length == 'j' || length == 'z' || length == 't' ||
			    length == 'q') {
				bytes = 8;
				if (length == 'l' && second == 'l')
					value = va_arg(ap, unsigned long long);
				else
					value = va_arg(ap, unsigned long);
			} else
				value = (uint32_t)va_arg(ap, unsigned int);
			add_argument(&data, 0, flags, bytes, value);
		}
	}
	va_end(ap);
	if (data.failed) {
		free(data.p);
		return NULL;
	}
	*size = data.n;
	return (void *)data.p;
}

/* Saved wire objects already contain their text description. */
char *finch_log_compose_saved(const char *f, const uint8_t *d, size_t n)
{
	return compose(f, d, n, 0, NULL, 0, true, false);
}
