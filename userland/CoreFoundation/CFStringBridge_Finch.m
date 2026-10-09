/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* String helpers used by the Swift runtime. Finch does not make tagged
 * strings, so the optional tagged-string path falls back to Swift storage. */
#include "CFObjCClasses_Finch.h"

CFStringRef
_CFStringCreateTaggedPointerString(const uint8_t *bytes, CFIndex count)
{
    return NULL;
}

BOOL
_NSIsNSString(id object)
{
    return [object isKindOfClass:[NSString class]];
}
