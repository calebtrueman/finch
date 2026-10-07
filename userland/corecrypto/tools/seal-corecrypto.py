#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Seal Finch's text sections after linking, before codesign.

This is an accidental-change check, not a FIPS certification or a substitute
for code signing. Runtime and file checks hash the contents of each __TEXT
section in Mach-O section order, excluding the 32-byte __finch_seal section.
"""
import argparse
import hashlib
from pathlib import Path
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64E = 2
LC_SEGMENT_64 = 0x19


def name(raw):
    return raw.split(b"\0", 1)[0]


def text_sections(data):
    if len(data) < 32:
        raise ValueError("Mach-O header is missing")
    magic, cpu, subtype, _, ncmds, cmdbytes, _, _ = struct.unpack_from("<8I", data)
    if magic != MH_MAGIC_64 or cpu != CPU_TYPE_ARM64 or subtype & 0xFFFFFF != CPU_SUBTYPE_ARM64E:
        raise ValueError("expected a thin arm64e Mach-O file")
    end = 32 + cmdbytes
    if end > len(data) or ncmds > cmdbytes // 8:
        raise ValueError("load commands extend past the file")
    cursor = 32
    result = None
    for _ in range(ncmds):
        if cursor + 8 > end:
            raise ValueError("truncated load command")
        command, size = struct.unpack_from("<2I", data, cursor)
        if size < 8 or size > end - cursor:
            raise ValueError("invalid load-command size")
        if command == LC_SEGMENT_64:
            if size < 72:
                raise ValueError("truncated segment")
            _, _, segname, vmaddr, vmsize, fileoff, filesize, _, _, count, _ = struct.unpack_from("<II16sQQQQIIII", data, cursor)
            if name(segname) == b"__TEXT":
                if result is not None or count > (size - 72) // 80:
                    raise ValueError("invalid text section table")
                if fileoff or filesize > vmsize or filesize > len(data) or filesize < end:
                    raise ValueError("invalid text segment bounds")
                result = []
                for i in range(count):
                    sect, seg, addr, length, offset, _, _, _, flags, _, _, _ = struct.unpack_from("<16s16sQQ8I", data, cursor + 72 + 80 * i)
                    relative = addr - vmaddr
                    if name(seg) != b"__TEXT" or relative < 0 or relative > filesize or length > filesize - relative or offset != relative:
                        raise ValueError("invalid text section bounds")
                    if flags & 0xFF in (1, 0xC, 0x12):
                        raise ValueError("zero-filled text sections are unsupported")
                    result.append((name(sect).decode("ascii"), offset, length))
        cursor += size
    if cursor != end or result is None:
        raise ValueError("missing text segment or invalid load commands")
    return result


def image_digest(data):
    sections = text_sections(data)
    seals = [(offset, size) for section, offset, size in sections if section == "__finch_seal"]
    if len(seals) != 1 or seals[0][1] != 32:
        raise ValueError("expected one 32-byte __TEXT,__finch_seal section")
    digest = hashlib.sha256()
    count = 0
    for section, offset, size in sections:
        if section != "__finch_seal":
            digest.update(data[offset:offset + size])
            count += 1
    if not count:
        raise ValueError("no text contents to seal")
    return digest.digest(), seals[0][0]


def verify(data):
    digest, offset = image_digest(data)
    expected = data[offset:offset + 32]
    return any(expected) and expected == digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("seal", "verify", "digest"))
    parser.add_argument("image", type=Path)
    args = parser.parse_args()
    try:
        data = args.image.read_bytes()
        digest, offset = image_digest(data)
        if args.action == "verify":
            if not verify(data):
                raise ValueError("text seal is missing or does not match")
            print(f"Verified text seal: {args.image}")
        elif args.action == "digest":
            print(digest.hex())
        else:
            with args.image.open("r+b") as image:
                if image.read() != data:
                    raise ValueError("image changed while sealing")
                image.seek(offset)
                image.write(digest)
            print(f"Sealed text sections: {args.image}; code signing must follow")
        return 0
    except (OSError, ValueError, struct.error, UnicodeError) as error:
        print(f"seal-corecrypto: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
