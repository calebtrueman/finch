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

#endif
