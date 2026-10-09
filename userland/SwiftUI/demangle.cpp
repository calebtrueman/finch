// SPDX-License-Identifier: MIT OR Apache-2.0
//
// The one demangler function Compute (SwiftUI's attribute graph) calls, which it takes from
// the toolchain's libswiftDemangle, a library an installed system doesn't have: the extent of a
// mangled name that may contain symbolic references. A reference is a control byte, 0x01-0x17
// followed by a 4-byte relative offset or 0x18-0x1f followed by an 8-byte pointer, so the
// name's own zero bytes can only end it outside one. (docs/ABI/Mangling.rst, "Symbolic
// references".)

#include <cstddef>

namespace swift {
namespace Demangle {

/* llvm::StringRef's layout, which is what the caller expects back (the return type isn't
   part of the mangled name). */
struct FinchStringRef {
    const char *data;
    size_t length;
};

__attribute__((visibility("hidden"))) FinchStringRef
makeSymbolicMangledNameStringRef(const char *base)
{
    if (!base)
        return {nullptr, 0};
    const unsigned char *p = reinterpret_cast<const unsigned char *>(base);
    while (*p) {
        unsigned char c = *p;
        if (c >= 0x01 && c <= 0x17)
            p += 1 + 4;
        else if (c >= 0x18 && c <= 0x1f)
            p += 1 + sizeof(void *);
        else
            p += 1;
    }
    return {base, static_cast<size_t>(reinterpret_cast<const char *>(p) - base)};
}

} // namespace Demangle
} // namespace swift
