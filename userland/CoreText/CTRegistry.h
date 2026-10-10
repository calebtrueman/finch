/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* The installed and process-registered fonts (CTFontRegistry.cpp). */
#ifndef CT_REGISTRY_H
#define CT_REGISTRY_H

#include "CTInternal.h"
#include <string>

struct CTInstalledFont {
    std::string path, postscript, full, family, style;
};

CT_PRIVATE const std::vector<CTInstalledFont> &CTInstalledFonts(void);
CT_PRIVATE bool CTFontRegistryRemoveGraphicsFont(CGFontRef font);
CT_PRIVATE std::vector<std::string> CTFontRegistryRegisteredNames(void);
/* The installed face of a family with these traits (bold, italic), or NULL. */
CT_PRIVATE CGFontRef CTFontRegistryCopyFamilyFace(CFStringRef family, bool bold, bool italic);

/* The installed face of a family nearest a weight (-1 to 1) and slant, how far from it it is
 * (10 more when the slant differs), or NULL when the family has no faces. */
CT_PRIVATE CGFontRef CTFontRegistryCopyNearestFace(CFStringRef family, CGFloat weight, bool italic, CGFloat *distance);

#endif
