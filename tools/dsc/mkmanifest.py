#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Write a dyld_shared_cache_builder JSON manifest for a root filesystem.

    mkmanifest.py <root> <manifest.json> [<exclude.txt>]

Every Mach-O dylib and executable with an arm64e slice under <root> becomes
an input. The builder decides which dylibs are eligible for the cache, and
builds prebuilt launch loaders for the executables (it needs at least one
in /usr/bin). Every symlink that resolves to one of the dylibs becomes a
manifest symlink, so framework aliases like Foo.framework/Foo ->
Versions/Current/Foo resolve in the cache. Paths listed in <exclude.txt>
(one per line, as in the image) are left out.
"""
import json
import os
import struct
import sys

MH_MAGIC_64, FAT_MAGIC, FAT_MAGIC_64 = 0xfeedfacf, 0xcafebabe, 0xcafebabf
MH_EXECUTE, MH_DYLIB = 2, 6
CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E = 0x0100000c, 2
SKIP_DIRS = ("/System/Library/dyld", "/private/var/db/dyld", "/usr/appleinternal")


def arm64e_filetype(path):
    """The Mach-O filetype of `path`'s arm64e slice (thin or fat), or None."""
    try:
        with open(path, "rb") as f:
            head = f.read(4096)
            magic = struct.unpack(">I", head[:4])[0] if len(head) >= 4 else 0
            if magic in (FAT_MAGIC, FAT_MAGIC_64):
                n = struct.unpack(">I", head[4:8])[0]
                size = 20 if magic == FAT_MAGIC else 32
                for i in range(min(n, 32)):
                    off = 8 + i * size
                    cpu, sub = struct.unpack(">ii", head[off:off + 8])
                    slice_off = (struct.unpack(">I", head[off + 8:off + 12])[0] if magic == FAT_MAGIC
                                 else struct.unpack(">Q", head[off + 8:off + 16])[0])
                    if cpu == CPU_TYPE_ARM64 and (sub & 0xff) == CPU_SUBTYPE_ARM64E:
                        f.seek(slice_off)
                        return thin_filetype(f.read(32))
                return None
            return thin_filetype(head[:32], want_arm64e=True)
    except OSError:
        return None


def thin_filetype(h, want_arm64e=False):
    if len(h) < 16 or struct.unpack("<I", h[:4])[0] != MH_MAGIC_64:
        return None
    cpu, sub, filetype = struct.unpack("<iiI", h[4:16])
    if want_arm64e and not (cpu == CPU_TYPE_ARM64 and (sub & 0xff) == CPU_SUBTYPE_ARM64E):
        return None
    return filetype


def main(root, out, exclude_file=None):
    root = os.path.realpath(root)
    exclude = set()
    if exclude_file and os.path.exists(exclude_file):
        exclude = {l.strip() for l in open(exclude_file) if l.strip()}
    dylibs, executables, links = set(), set(), []
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = "/" + os.path.relpath(dirpath, root) if dirpath != root else ""
        if rel_dir.startswith(SKIP_DIRS):
            dirnames[:] = []
            continue
        for name in filenames + [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]:
            full = os.path.join(dirpath, name)
            rel = rel_dir + "/" + name
            if os.path.islink(full):
                links.append((rel, full))
            elif os.path.isfile(full) and rel not in exclude:
                kind = arm64e_filetype(full)
                if kind == MH_DYLIB:
                    dylibs.add(rel)
                elif kind == MH_EXECUTE:
                    executables.add(rel)
    symlinks = []
    for rel, full in sorted(links):
        target = os.path.realpath(full)
        if target.startswith(root + "/"):
            target_rel = target[len(root):]
            if target_rel in dylibs:
                symlinks.append({"path": rel, "target": target_rel})
    manifest = {
        "version": 1,
        "buildOptions": {
            "version": 3,
            "updateName": "Finch",
            "deviceName": "Finch",
            "disposition": "Customer",
            "platform": "macOS",
            "archs": ["arm64e"],
            "optimizeForSize": False,
            "filesRemovedFromDisk": True,
        },
        "files": [{"path": p, "flags": "NoFlags"} for p in sorted(dylibs | executables)],
        "symlinks": symlinks,
    }
    with open(out, "w") as f:
        json.dump(manifest, f, indent=1)
    print(f"{len(dylibs)} dylibs, {len(executables)} executables, {len(symlinks)} symlinks"
          + (f", {len(exclude)} left out" if exclude else "") + f" -> {out}")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    main(*sys.argv[1:])
