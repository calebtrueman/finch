/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * Finch's CoreUI internals: the compiled asset catalog reader in C
 * (CUIStore.c: the BOM container and the catalog's trees; CUIRendition.c:
 * CSI renditions and their payloads; CUIDeepmap.c: the deepmap2 codec), under
 * the Objective-C API in CUICatalog.m. docs/design/ASSETS.md describes the
 * format.
 */
#ifndef CUIPRIVATE_H
#define CUIPRIVATE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Rendition key attributes, as the KEYFORMAT block numbers them (kCRTheme...Name). */
enum {
	CUI_ATTR_ELEMENT = 1,
	CUI_ATTR_PART = 2,
	CUI_ATTR_SIZE = 3,
	CUI_ATTR_DIRECTION = 4,
	CUI_ATTR_VALUE = 6,
	CUI_ATTR_APPEARANCE = 7,
	CUI_ATTR_DIMENSION1 = 8,
	CUI_ATTR_DIMENSION2 = 9,
	CUI_ATTR_STATE = 10,
	CUI_ATTR_LAYER = 11,
	CUI_ATTR_SCALE = 12,
	CUI_ATTR_LOCALIZATION = 13,
	CUI_ATTR_PRESENTATION_STATE = 14,
	CUI_ATTR_IDIOM = 15,
	CUI_ATTR_SUBTYPE = 16,
	CUI_ATTR_IDENTIFIER = 17,
	CUI_ATTR_PREVIOUS_VALUE = 18,
	CUI_ATTR_PREVIOUS_STATE = 19,
	CUI_ATTR_SIZE_CLASS_H = 20,
	CUI_ATTR_SIZE_CLASS_V = 21,
	CUI_ATTR_MEMORY_CLASS = 22,
	CUI_ATTR_GRAPHICS_CLASS = 23,
	CUI_ATTR_GAMUT = 24,
	CUI_ATTR_DEPLOYMENT = 25,
	CUI_ATTR_GLYPH_WEIGHT = 26,
	CUI_ATTR_GLYPH_SIZE = 27,
	CUI_ATTR_MAX = 32
};

typedef struct {
	uint16_t v[CUI_ATTR_MAX];
} cui_key;

typedef struct {
	cui_key key;
	const uint8_t *csi;
	uint32_t len;
	uint32_t index;  /* in the tree's order */
} cui_rendition;

typedef struct {
	char *name;
	cui_key attrs;  /* the facet's rendition key token */
	uint32_t mask;  /* which attributes the token sets */
} cui_facet;

typedef struct {
	char *name;
	uint16_t id;
} cui_appearance;

typedef struct cui_store {
	void *map;
	size_t size;
	bool mapped;
	const uint8_t *data;
	/* CARHEADER */
	uint32_t coreui_version, storage_version, timestamp, rendition_count, schema, colorspace, key_semantics;
	char main_version[129], version_string[257];
	/* KEYFORMAT */
	uint32_t nattrs, attrs[CUI_ATTR_MAX];
	cui_rendition *rends;  /* by identifier, then in the tree's order */
	size_t nrends;
	cui_facet *facets;  /* sorted by name, as the tree is */
	size_t nfacets;
	cui_appearance *apps;
	size_t napps;
} cui_store;

cui_store *cui_store_open(const char *path);
cui_store *cui_store_open_bytes(const void *bytes, size_t len);
void cui_store_free(cui_store *s);
const cui_facet *cui_store_facet(const cui_store *s, const char *name);
/* true and the id when the catalog lists the appearance */
bool cui_store_appearance(const cui_store *s, const char *name, uint16_t *id);
const char *cui_store_appearance_name(const cui_store *s, uint16_t id);
/* the renditions with an identifier: [*first, *first + count) */
size_t cui_store_renditions_for_identifier(const cui_store *s, uint16_t ident, size_t *first);
const cui_rendition *cui_store_rendition_with_key(const cui_store *s, const cui_key *key);

/* MARK: CSI renditions */

/* Layouts (the CSI header's) */
enum {
	CUI_LAYOUT_GRADIENT = 6,
	CUI_LAYOUT_EFFECT = 7,
	CUI_LAYOUT_VECTOR = 9,
	CUI_LAYOUT_DATA = 1000,
	CUI_LAYOUT_EXTERNAL_LINK = 1001,
	CUI_LAYOUT_LAYER_STACK = 1002,
	CUI_LAYOUT_INTERNAL_LINK = 1003,
	CUI_LAYOUT_PACKED_IMAGE = 1004,
	CUI_LAYOUT_NAME_LIST = 1005,
	CUI_LAYOUT_TEXTURE = 1007,
	CUI_LAYOUT_COLOR = 1009,
	CUI_LAYOUT_MULTISIZE_IMAGE_SET = 1010,
	CUI_LAYOUT_VECTOR_GLYPH = 1017,
	CUI_LAYOUT_ICON_STACK = 1019,
	CUI_LAYOUT_ICON_GROUP = 1020,
	CUI_LAYOUT_NAMED_GRADIENT = 1021,
};

/* TLV types in the CSI header's extension area */
enum {
	CUI_TLV_SLICES = 1001,
	CUI_TLV_METRICS = 1003,
	CUI_TLV_BLEND = 1004,
	CUI_TLV_UTI = 1005,
	CUI_TLV_EXIF = 1006,
	CUI_TLV_ROWBYTES = 1007,
	CUI_TLV_LINK = 1010,
};

#define CUI_FOURCC(a, b, c, d) ((uint32_t)(a) << 24 | (uint32_t)(b) << 16 | (uint32_t)(c) << 8 | (uint32_t)(d))

typedef struct {
	uint32_t version, flags, width, height, scale100, pixel_format, colorspace;
	uint16_t layout;
	char name[129];
	const uint8_t *tlv;
	uint32_t tlv_len;
	const uint8_t *data;
	uint32_t data_len;
} cui_csi;

bool cui_csi_parse(const uint8_t *p, uint32_t len, cui_csi *out);
const uint8_t *cui_csi_tlv(const cui_csi *c, uint32_t type, uint32_t *len);
/* rendition flags: bit 2 vector-based, bits 3-4 template rendering mode */
static inline bool cui_csi_is_vector(const cui_csi *c) { return (c->flags >> 2) & 1; }
static inline unsigned cui_csi_template_mode(const cui_csi *c) { return (c->flags >> 3) & 3; }

typedef struct {
	uint8_t *pixels;  /* malloc'd */
	size_t width, height, rowbytes;
	unsigned bpp;      /* bytes per pixel */
	uint32_t format;   /* 'ARGB' (BGRA, premultiplied), 'GA8 ', 'RGBW' (RGBA half floats) */
	bool opaque;
	bool native;      /* stored uncompressed: CoreUI hands these out as they are */
} cui_bitmap;

bool cui_csi_decode_bitmap(const cui_csi *c, cui_bitmap *out);
/* raw data ('DWAR'), decompressed when it is LZFSE; malloc'd */
uint8_t *cui_csi_raw_data(const cui_csi *c, size_t *len);
/* colour ('COLR'): the colour space id, components (up to 8) and the system colour name, if any */
bool cui_csi_color(const cui_csi *c, unsigned *space, double *comps, unsigned *ncomps, char *sysname, size_t sysname_len);
/* an internal link ('INLK'): the atlas key's attributes and the frame in it */
bool cui_csi_link(const cui_csi *c, cui_key *key, uint32_t frame[4], unsigned *layout);
/* the image layout a bitmap rendition had before packing (the CSI's own when not linked) */
unsigned cui_csi_image_layout(const cui_csi *c);

/* MARK: Codecs */

bool cui_lz_decode(const uint8_t *src, size_t srclen, uint8_t *dst, size_t n);
unsigned cui_deepmap2_format(const uint8_t *src, size_t len);
bool cui_deepmap2_decode(const uint8_t *src, size_t len, uint8_t *dst, size_t rowbytes, size_t width, size_t height);

#endif
