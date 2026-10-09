/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGImageMetadata: the CF types, so code that checks type IDs or makes an
 * empty mutable metadata object works. XMP reading and writing are not
 * written yet; sources report no metadata (CGImageSourceCopyMetadataAtIndex
 * returns NULL, as it does for a file without any).
 */
#include "ImageIOInternal.h"

struct CGImageMetadata {
    IIORuntimeBase base;
};

struct CGImageMetadataTag {
    IIORuntimeBase base;
};

static CFTypeID metadata_type_id, tag_type_id;

static const IIORuntimeClass metadata_class = {
    0, "CGImageMetadata", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};

static const IIORuntimeClass tag_class = {
    0, "CGImageMetadataTag", NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 0,
};

CFTypeID
CGImageMetadataGetTypeID(void)
{
    return IIOTypeRegister(&metadata_class, &metadata_type_id);
}

CFTypeID
CGImageMetadataTagGetTypeID(void)
{
    return IIOTypeRegister(&tag_class, &tag_type_id);
}

CGMutableImageMetadataRef
CGImageMetadataCreateMutable(void)
{
    return (CGMutableImageMetadataRef)IIOTypeCreateInstance(CGImageMetadataGetTypeID(), sizeof(struct CGImageMetadata));
}

CGMutableImageMetadataRef
CGImageMetadataCreateMutableCopy(CGImageMetadataRef metadata)
{
    return metadata ? CGImageMetadataCreateMutable() : NULL;
}

CFArrayRef
CGImageMetadataCopyTags(CGImageMetadataRef metadata)
{
    return metadata ? CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks) : NULL;
}
