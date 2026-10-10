#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Give the emulated M4's device tree Apple silicon's timebase (24 MHz).

darwin-vm's device tree runs the CPU's timer at 0x100000 Hz. QEMU takes the generic timer's
frequency from cpus/cpu0's clock-frequency, and XNU its timebase from timebase-frequency.
Code built for Apple silicon assumes the 24 MHz timebase: Swift's runtime turns a sleep's
deadline into mach ticks at 125/3 per nanosecond, so at 1 MHz `Task.sleep` waited some 23
times its uptime. Both properties of cpu0 become 24000000, the rest of the tree as it was.
    tools/vm/dtree-timebase.py IN OUT
"""
import struct
import sys

TIMEBASE = 24_000_000
PROPS = (b"clock-frequency", b"timebase-frequency")


def walk(data, offset, path, patches):
    """Walk the node at offset (Apple's format: property and child counts, then the
    properties as 32-byte name, length and value padded to 4, then the children);
    collect the offsets of cpu0's frequency values. Returns the offset after the node."""
    nprops, nchildren = struct.unpack_from("<II", data, offset)
    offset += 8
    name = None
    props = []
    for _ in range(nprops):
        pname = data[offset:offset + 32].split(b"\0", 1)[0]
        length = struct.unpack_from("<I", data, offset + 32)[0] & 0x7FFFFFFF
        value_at = offset + 36
        if pname == b"name":
            name = data[value_at:value_at + length].split(b"\0", 1)[0]
        props.append((pname, value_at, length))
        offset = value_at + ((length + 3) & ~3)
    here = path + [name or b"?"]
    if here[-2:] == [b"cpus", b"cpu0"]:
        for pname, value_at, length in props:
            if pname in PROPS and length == 4:
                patches.append(value_at)
    for _ in range(nchildren):
        offset = walk(data, offset, here, patches)
    return offset


def main():
    src, dst = sys.argv[1:3]
    data = bytearray(open(src, "rb").read())
    patches = []
    walk(data, 0, [], patches)
    if len(patches) != len(PROPS):
        sys.exit(f"{src}: expected cpus/cpu0's {len(PROPS)} frequencies, found {len(patches)}")
    for at in patches:
        struct.pack_into("<I", data, at, TIMEBASE)
    open(dst, "wb").write(data)


if __name__ == "__main__":
    main()
