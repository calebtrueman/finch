// SPDX-License-Identifier: MIT OR Apache-2.0
// The CoreImage overlay. Apple's exports nothing but its force-load symbol
// (CoreImage's Swift refinements are in the framework itself); Finch's is
// the same empty module, so apps that link it load.
