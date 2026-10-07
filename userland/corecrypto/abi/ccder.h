/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCDER_H
#define FINCH_ABI_CCDER_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
typedef uint64_t ccder_tag;
#define CCDER_SEQUENCE (UINT64_C(0x2000000000000000) | 16)
struct ccder_blob {
	unsigned char *start, *end;
};
struct ccder_read_blob {
	const unsigned char *start, *end;
};
size_t ccder_sizeof_tag(ccder_tag);
size_t ccder_sizeof_len(size_t);
size_t ccder_sizeof(ccder_tag, size_t);
size_t ccder_sizeof_overflow(ccder_tag, size_t, bool *);
bool ccder_blob_encode_tag(struct ccder_blob *, ccder_tag);
bool ccder_blob_encode_len(struct ccder_blob *, size_t);
bool ccder_blob_encode_tl(struct ccder_blob *, ccder_tag, size_t);
bool ccder_blob_reserve(struct ccder_blob *, size_t, struct ccder_blob *);
bool ccder_blob_reserve_tl(struct ccder_blob *, ccder_tag, size_t, struct ccder_blob *);
bool ccder_blob_encode_body(struct ccder_blob *, size_t, const void *);
bool ccder_blob_encode_body_tl(struct ccder_blob *, ccder_tag, size_t, const void *);
bool ccder_blob_decode_tag(struct ccder_read_blob *, ccder_tag *);
#define DECLARE_DECODE(suffix)                                                                     \
	bool ccder_blob_decode_len##suffix(struct ccder_read_blob *, size_t *);                    \
	bool ccder_blob_decode_tl##suffix(struct ccder_read_blob *, ccder_tag, size_t *);          \
	bool ccder_blob_decode_range##suffix(                                                      \
	    struct ccder_read_blob *, ccder_tag, struct ccder_read_blob *);                        \
	bool ccder_blob_decode_sequence_tl##suffix(                                                \
	    struct ccder_read_blob *, struct ccder_read_blob *);                                   \
	const unsigned char *ccder_decode_len##suffix(                                             \
	    size_t *, const unsigned char *, const unsigned char *);                               \
	const unsigned char *ccder_decode_tl##suffix(                                              \
	    ccder_tag, size_t *, const unsigned char *, const unsigned char *);                    \
	const unsigned char *ccder_decode_constructed_tl##suffix(                                  \
	    ccder_tag, const unsigned char **, const unsigned char *, const unsigned char *);      \
	const unsigned char *ccder_decode_sequence_tl##suffix(                                     \
	    const unsigned char **, const unsigned char *, const unsigned char *);
DECLARE_DECODE()
DECLARE_DECODE(_strict)
#undef DECLARE_DECODE
unsigned char *ccder_encode_tag(ccder_tag, unsigned char *, unsigned char *);
unsigned char *ccder_encode_len(size_t, unsigned char *, unsigned char *);
unsigned char *ccder_encode_tl(ccder_tag, size_t, unsigned char *, unsigned char *);
unsigned char *ccder_encode_body(size_t, const void *, unsigned char *, unsigned char *);
unsigned char *ccder_encode_body_nocopy(size_t, unsigned char *, unsigned char *);
unsigned char *ccder_encode_constructed_tl(
    ccder_tag, const unsigned char *, unsigned char *, unsigned char *);
const unsigned char *ccder_decode_tag(ccder_tag *, const unsigned char *, const unsigned char *);
#include "ccn.h"
#define INTEGER_API(suffix)                                                                        \
	bool ccder_blob_decode_uint##suffix(struct ccder_read_blob *, size_t, cc_unit *);          \
	const unsigned char *ccder_decode_uint##suffix(                                            \
	    size_t, cc_unit *, const unsigned char *, const unsigned char *);
INTEGER_API()
INTEGER_API(_strict)
#undef INTEGER_API
bool ccder_blob_decode_uint_n(struct ccder_read_blob *, size_t *);
bool ccder_blob_decode_uint64(struct ccder_read_blob *, uint64_t *);
const unsigned char *ccder_decode_uint_n(size_t *, const unsigned char *, const unsigned char *);
const unsigned char *ccder_decode_uint64(uint64_t *, const unsigned char *, const unsigned char *);
#define NUMBER_API(name)                                                                           \
	size_t ccder_sizeof_implicit_##name(ccder_tag, size_t, const cc_unit *);                   \
	size_t ccder_sizeof_##name(size_t, const cc_unit *);                                       \
	bool ccder_blob_encode_implicit_##name(                                                    \
	    struct ccder_blob *, ccder_tag, size_t, const cc_unit *);                              \
	bool ccder_blob_encode_##name(struct ccder_blob *, size_t, const cc_unit *);               \
	unsigned char *ccder_encode_implicit_##name(                                               \
	    ccder_tag, size_t, const cc_unit *, unsigned char *, unsigned char *);                 \
	unsigned char *ccder_encode_##name(                                                        \
	    size_t, const cc_unit *, unsigned char *, unsigned char *);
NUMBER_API(integer)
NUMBER_API(octet_string)
#undef NUMBER_API
size_t ccder_sizeof_implicit_uint64(ccder_tag, uint64_t);
size_t ccder_sizeof_uint64(uint64_t);
bool ccder_blob_encode_implicit_uint64(struct ccder_blob *, ccder_tag, uint64_t);
bool ccder_blob_encode_uint64(struct ccder_blob *, uint64_t);
unsigned char *ccder_encode_implicit_uint64(ccder_tag, uint64_t, unsigned char *, unsigned char *);
unsigned char *ccder_encode_uint64(uint64_t, unsigned char *, unsigned char *);
size_t ccder_sizeof_implicit_raw_octet_string(ccder_tag, size_t);
size_t ccder_sizeof_raw_octet_string(size_t);
size_t ccder_sizeof_implicit_raw_octet_string_overflow(ccder_tag, size_t, bool *);
bool ccder_blob_encode_implicit_raw_octet_string(
    struct ccder_blob *, ccder_tag, size_t, const void *);
bool ccder_blob_encode_raw_octet_string(struct ccder_blob *, size_t, const void *);
unsigned char *ccder_encode_implicit_raw_octet_string(
    ccder_tag, size_t, const void *, unsigned char *, unsigned char *);
unsigned char *ccder_encode_raw_octet_string(
    size_t, const void *, unsigned char *, unsigned char *);
size_t ccder_sizeof_oid(const unsigned char *);
bool ccder_blob_encode_oid(struct ccder_blob *, const unsigned char *);
unsigned char *ccder_encode_oid(const unsigned char *, unsigned char *, unsigned char *);
bool ccder_blob_decode_oid(struct ccder_read_blob *, const unsigned char **);
const unsigned char *ccder_decode_oid(
    const unsigned char **, const unsigned char *, const unsigned char *);
bool ccder_blob_decode_bitstring(struct ccder_read_blob *, struct ccder_read_blob *, size_t *);
const unsigned char *ccder_decode_bitstring(
    const unsigned char **, size_t *, const unsigned char *, const unsigned char *);
bool ccder_blob_decode_seqii(struct ccder_read_blob *, size_t, cc_unit *, cc_unit *);
bool ccder_blob_decode_seqii_strict(struct ccder_read_blob *, size_t, cc_unit *, cc_unit *);
const unsigned char *ccder_decode_seqii(
    size_t, cc_unit *, cc_unit *, const unsigned char *, const unsigned char *);
const unsigned char *ccder_decode_seqii_strict(
    size_t, cc_unit *, cc_unit *, const unsigned char *, const unsigned char *);
size_t ccder_sizeof_eckey(size_t, const unsigned char *, size_t);
size_t ccder_encode_eckey_size(size_t, const unsigned char *, size_t);
bool ccder_blob_encode_eckey(
    struct ccder_blob *, size_t, const void *, const unsigned char *, size_t, const void *);
unsigned char *ccder_encode_eckey(size_t, const void *, const unsigned char *, size_t, const void *,
    unsigned char *, unsigned char *);
bool ccder_blob_decode_eckey(struct ccder_read_blob *, uint64_t *, size_t *, const unsigned char **,
    const unsigned char **, size_t *, const unsigned char **, size_t *);
const unsigned char *ccder_decode_eckey(uint64_t *, size_t *, const unsigned char **,
    const unsigned char **, size_t *, const unsigned char **, const unsigned char *,
    const unsigned char *);
size_t ccder_decode_rsa_pub_n(const unsigned char *, const unsigned char *);
size_t ccder_decode_rsa_priv_n(const unsigned char *, const unsigned char *);
size_t ccder_decode_rsa_pub_x509_n(const unsigned char *, const unsigned char *);
size_t ccder_decode_dhparam_n(const unsigned char *, const unsigned char *);
#endif
