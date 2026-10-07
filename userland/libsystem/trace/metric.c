/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "metric.h"
#include <os/object.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
extern struct finch_log *os_log_create(const char *, const char *);
extern const void *_dyld_get_shared_cache_range(size_t *);
static pthread_mutex_t metric_lock = PTHREAD_MUTEX_INITIALIZER;
static size_t stats_size(unsigned n)
{
	return n < 3 ? 8 + 40 * n : 0;
}
static void *flatten(const struct metric_label_part *parts, size_t count, size_t *size)
{
	size_t total = 0;
	for (size_t i = 0; i < count; i++) {
		unsigned type = parts[i].type & 255;
		size_t n = type == 1 ? 4 : type == 2 ? 6 : type ? 0 : strlen(parts[i].value);
		if (n > 4095 || total + n + 14 > 2048)
			return NULL;
		total += n + 2;
	}
	unsigned char *out = calloc(1, total ? total : 1);
	if (!out)
		return NULL;
	size_t at = 0;
	for (size_t i = 0; i < count; i++) {
		unsigned type = parts[i].type & 255;
		size_t n = type == 1 ? 4 : type == 2 ? 6 : type ? 0 : strlen(parts[i].value);
		uint16_t header = n | (type << 12);
		memcpy(out + at, &header, 2);
		at += 2;
		if (n)
			memcpy(out + at, type ? (const void *)&parts[i].value : parts[i].value, n);
		at += n;
	}
	*size = total;
	return out;
}
API struct metric_label *_os_metric_label_create_v(
    const void *image, size_t count, const struct metric_label_part *input)
{
	if (count > SIZE_MAX / sizeof(*input))
		return NULL;
	struct metric_label_part *parts = calloc(count ? count : 1, sizeof(*parts)),
	                         *strings = calloc(count ? count : 1, sizeof(*strings));
	if (!parts || !strings) {
		free(parts);
		free(strings);
		return NULL;
	}
	size_t cache_size = 0;
	uintptr_t cache = (uintptr_t)_dyld_get_shared_cache_range(&cache_size),
	          base = (uintptr_t)image;
	if (base >= cache && base - cache < cache_size)
		base = cache;
	bool has_strings = false;
	for (size_t i = 0; i < count; i++) {
		parts[i] = input[i];
		strings[i] = (struct metric_label_part){0, input[i].value};
		if ((input[i].type & 255) == 1) {
			uintptr_t offset = input[i].value ? (uintptr_t)input[i].value - base : 0;
			uint64_t packed = (offset & 0x7fffffff) | ((offset >> 31 & 0xffff) << 32);
			parts[i] = (struct metric_label_part){
			    offset >> 31 & 0xffff ? 2 : 1, (const char *)(uintptr_t)packed};
			has_strings = true;
		} else
			parts[i].type = 0;
	}
	size_t n = 0, sn = 0;
	void *data = flatten(parts, count, &n), *text = NULL;
	if (data && has_strings)
		text = flatten(strings, count, &sn);
	free(parts);
	free(strings);
	if (!data || (has_strings && !text)) {
		free(data);
		free(text);
		return NULL;
	}
	struct metric_label *out = finch_metric_allocate(0, sizeof(*out));
	out->data = data;
	out->size = n;
	out->strings = text;
	out->strings_size = sn;
	return out;
}
API struct metric_label *_os_metric_label_create_impl(
    const void *image, size_t count, uint64_t type, const char *value, ...)
{
	if (count > SIZE_MAX / sizeof(struct metric_label_part))
		return NULL;
	struct metric_label_part *parts = calloc(count ? count : 1, sizeof(*parts));
	if (!parts)
		return NULL;
	va_list args;
	va_start(args, value);
	for (size_t i = 0; i < count; i++) {
		parts[i] = (struct metric_label_part){type, value};
		if (i + 1 < count) {
			type = va_arg(args, uint64_t);
			value = va_arg(args, const char *);
		}
	}
	va_end(args);
	struct metric_label *out = _os_metric_label_create_v(image, count, parts);
	free(parts);
	return out;
}
API struct metric_dimensions *os_metric_dimensions_create(unsigned count)
{
	struct metric_dimensions *out = finch_metric_allocate(1, sizeof(*out));
	out->capacity = count;
	out->labels = calloc(count ? count : 1, sizeof(*out->labels));
	return out;
}
API bool os_metric_dimensions_add(struct metric_dimensions *d, const char *key, const char *value)
{
	if (d->count == d->capacity)
		return false;
	struct metric_label_part parts[] = {{0, key}, {0, value}};
	struct metric_label *label = _os_metric_label_create_v(NULL, 2, parts);
	if (!label)
		return false;
	d->labels[d->count++] = label;
	return true;
}
API struct metric_group *os_metric_group_create(
    const char *subsystem, const char *category, struct metric_dimensions *d)
{
	struct metric_group *g = finch_metric_allocate(2, sizeof(*g));
	g->log = os_log_create(subsystem, category);
	if (d)
		g->dimensions = os_retain(d);
	return g;
}
static void reset_data(struct metric *m)
{
	size_t n = stats_size(m->stats);
	memset(m->data, 0, n + 8 * m->bins);
	if (m->stats == 1 || m->stats == 2) {
		m->data[2] = m->type == 0 ? INT64_MAX
		    : m->type == 1        ? UINT64_C(0x7ff0000000000000)
		                          : UINT64_MAX;
		m->data[3] = m->type == 0 ? UINT64_C(0x8000000000000000)
		    : m->type == 1        ? UINT64_C(0xfff0000000000000)
		                          : 0;
	}
	if (m->stats == 2) {
		double alpha = .9;
		memcpy(&m->data[6], &alpha, 8);
	}
}
static struct metric *create(struct metric_group *g, const char *label, struct metric_dimensions *d,
    unsigned kind, unsigned type, unsigned stats, unsigned bins, unsigned width, unsigned option)
{
	if (!label || bins > 128)
		__builtin_trap();
	struct metric *m = finch_metric_allocate(3, sizeof(*m) + stats_size(stats) + 8 * bins);
	m->group = os_retain(g);
	m->label = _os_metric_label_create_impl(NULL, 1, 0, label);
	if (d)
		m->dimensions = os_retain(d);
	m->kind = kind;
	m->type = type;
	m->stats = stats;
	m->bins = bins;
	m->width = width;
	m->option = option;
	reset_data(m);
	return m;
}
#define MAKE(name, type)                                                                           \
	API struct metric *_os_metric_##name##_create_impl(struct metric_group *g, const char *l,  \
	    struct metric_dimensions *d, unsigned k, unsigned s, unsigned b, unsigned w,           \
	    unsigned o)                                                                            \
	{                                                                                          \
		return create(g, l, d, k, type, s, b, w, o);                                       \
	}
MAKE(int64, 0)
MAKE(double, 1) MAKE(uint64, 2) API void _os_metric_set_scale_impl(struct metric *m, unsigned n)
{
	m->scale = n;
}
API void _os_metric_set_unit_impl(struct metric *m, unsigned n)
{
	m->unit = n;
}
static void emit(struct metric *m, const void *image, const void *pc, uint64_t value)
{
	if (!m->group || !m->group->log || !m->label)
		return;
	struct metric_dimensions *ds[] = {m->group->dimensions, m->dimensions};
	size_t stats = stats_size(m->stats) + 8 * m->bins, size = 16 + stats + m->label->size;
	for (unsigned i = 0; i < 2; i++)
		if (ds[i])
			for (unsigned j = 0; j < ds[i]->count; j++)
				size += ds[i]->labels[j]->size;
	unsigned char *p = malloc(size);
	if (!p)
		return;
	memcpy(p, &m->kind, 16);
	memcpy(p + 16, m->data, stats);
	size_t at = 16 + stats;
	memcpy(p + at, m->label->data, m->label->size);
	at += m->label->size;
	for (unsigned i = 0; i < 2; i++)
		if (ds[i])
			for (unsigned j = 0; j < ds[i]->count; j++) {
				struct metric_label *l = ds[i]->labels[j];
				memcpy(p + at, l->data, l->size);
				at += l->size;
			}
	finch_trace_metric_send(m->group->log, m->type, image, pc, value, p, size);
	free(p);
}
static double read_double(const uint64_t *p)
{
	double v;
	memcpy(&v, p, 8);
	return v;
}
static void write_double(uint64_t *p, double v)
{
	memcpy(p, &v, 8);
}
static void extended(struct metric *m, double value)
{
	uint64_t *d = m->data;
	double old = read_double(d + 9), mean = value, variance = 0;
	if (d[1] >= 2) {
		mean = old + (value - old) / (double)d[1];
		variance = fma(value - old, value - mean, read_double(d + 10));
	}
	write_double(d + 9, mean);
	write_double(d + 10, variance);
	double weight = read_double(d + 7), average = value;
	if (weight > 0) {
		weight = fma(read_double(d + 6), weight, 1);
		double alpha = 1 / weight;
		average = fma(1 - alpha, read_double(d + 8), alpha * value);
	} else
		weight = 1;
	write_double(d + 7, weight);
	write_double(d + 8, average);
}
static void integer_op(
    struct metric *m, unsigned op, uint64_t value, const void *image, const void *pc, bool sign)
{
	if (m->stats > 2)
		abort();
	pthread_mutex_lock(&metric_lock);
	uint64_t *d = m->data;
	if (op == 0)
		d[0] += value;
	else if (op == 1)
		d[0] -= value;
	else if (op == 2)
		d[0] = value;
	if (m->stats) {
		d[4] += d[0];
		d[1]++;
		if (sign ? (int64_t)d[0] > (int64_t)d[3] : d[0] > d[3])
			d[3] = d[0];
		if (sign ? (int64_t)d[0] < (int64_t)d[2] : d[0] < d[2])
			d[2] = d[0];
		if (m->stats == 2)
			extended(m, sign ? (double)(int64_t)d[0] : (double)d[0]);
	}
	if (m->bins) {
		uint64_t bin = 0;
		if (!sign || (int64_t)d[0] > 0)
			bin = m->width ? d[0] / m->width : d[0] ? 64 - __builtin_clzll(d[0]) : 0;
		unsigned index = (uint32_t)bin < m->bins ? (uint32_t)bin : m->bins - 1;
		d[stats_size(m->stats) / 8 + index]++;
	}
	emit(m, image, pc, m->kind ? d[0] : op == 1 ? 0 - value : value);
	pthread_mutex_unlock(&metric_lock);
}
API void _os_metric_uint64_op_impl(struct metric *m, unsigned op, uint64_t value, const void *image)
{
	integer_op(m, op, value, image, __builtin_return_address(0), false);
}
API void _os_metric_int64_op_impl(struct metric *m, unsigned op, int64_t value, const void *image)
{
	integer_op(m, op, value, image, __builtin_return_address(0), true);
}
static uint64_t unsigned_double(double x)
{
	if (!(x > 0))
		return 0;
	if (x >= 18446744073709551616.0)
		return UINT64_MAX;
	return (uint64_t)x;
}
API void _os_metric_double_op_impl(struct metric *m, unsigned op, double value, const void *image)
{
	if (m->stats > 2)
		abort();
	pthread_mutex_lock(&metric_lock);
	uint64_t *d = m->data;
	double current = read_double(d);
	if (op == 0)
		current = value + current;
	else if (op == 1)
		current -= value;
	else if (op == 2)
		current = value;
	write_double(d, current);
	if (m->stats) {
		write_double(d + 4, current + read_double(d + 4));
		d[1]++;
		if (current > read_double(d + 3))
			write_double(d + 3, current);
		if (current < read_double(d + 2))
			write_double(d + 2, current);
		if (m->stats == 2)
			extended(m, current);
	}
	if (m->bins) {
		uint64_t bin = m->width ? unsigned_double(current / m->width)
		    : current >= 1      ? unsigned_double(floor(log2(current)) + 1)
		                        : 0;
		if (bin > UINT32_MAX)
			bin = UINT32_MAX;
		unsigned index = (uint32_t)bin < m->bins ? (uint32_t)bin : m->bins - 1;
		d[stats_size(m->stats) / 8 + index]++;
	}
	uint64_t count = unsigned_double(value);
	emit(m, image, __builtin_return_address(0), m->kind ? d[0] : op == 1 ? 0 - count : count);
	pthread_mutex_unlock(&metric_lock);
}
API void _os_metric_reset_impl(struct metric *m, const void *image)
{
	pthread_mutex_lock(&metric_lock);
	uint64_t old = m->data[0];
	reset_data(m);
	emit(m, image, __builtin_return_address(0), m->kind ? m->data[0] : 0 - old);
	pthread_mutex_unlock(&metric_lock);
}
