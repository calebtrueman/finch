/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Definitions the cache builder links against but Apple's published dyld
 * source doesn't contain.
 */

#include <span>

#include "ChainedFixups.h"
#include "SharedCacheLinker.h"

/*
 * SharedCacheLinker.framework is built from ld/ sources that aren't published.
 * The cache builder uses it only to synthesize optional dylibs (stub dylibs
 * for elided libraries and libswiftPrespecialized.dylib), and treats a failure
 * as "not built" and carries on.
 */
LD_EXPORT const char *
ldMakeDylibFromJSON(std::span<const char> jsonData, std::span<const char *> dylibList, const char *outputPath)
{
	(void)jsonData; (void)dylibList; (void)outputPath;
	return "dylib synthesis is not available in Finch's cache builder (no published linker)";
}

/*
 * The base-class version of a virtual that every concrete pointer format
 * overrides (mach_o/ChainedFixups.cpp). Only an unknown format reaches it.
 */
mach_o::Error
mach_o::ChainedFixups::PointerFormat::writeChainEntry(const Fixup &fixup, const void *nextLoc,
    uint64_t preferedLoadAddress, std::span<const MappedSegment *> segments) const
{
	(void)fixup; (void)nextLoc; (void)preferedLoadAddress; (void)segments;
	return Error("writing chained fixups isn't supported for pointer format %s", this->name());
}
