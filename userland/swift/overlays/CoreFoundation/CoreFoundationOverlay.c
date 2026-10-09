// SPDX-License-Identifier: MIT OR Apache-2.0
// Symbols Apple's libswiftCoreFoundation exports besides the Swift ones:
// the project version (Xcode's apple-generic versioning) and the force-load
// symbol of the CoreGraphics overlay, whose CGFloat this library now carries.
const double CoreFoundationVersionNumber = 120.1;
const unsigned char CoreFoundationVersionString[] =
    "@(#)PROGRAM:CoreFoundation  PROJECT:Foundation-swiftoverlay-120.100\n";
__attribute__((visibility("default"))) char swift_FORCE_LOAD_swiftCoreGraphics
    __asm("__swift_FORCE_LOAD_$_swiftCoreGraphics") = 0;
