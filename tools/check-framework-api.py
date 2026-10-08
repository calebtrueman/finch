#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""How much of a framework's API does Finch's build export, and in the right
image?

    tools/check-framework-api.py [-v] Foundation CoreFoundation ...

For each framework, the SDK's text stub (.tbd) lists what Apple's binary
exports for arm64e macOS: Objective-C classes and other symbols. Finch's
build (build/root/System/Library/Frameworks/<name>.framework) is compared
with it. A class matters in the image Apple puts it in: binaries built
against the SDK bind it there (NSCache and NSOrderedSet are CoreFoundation's,
not Foundation's), so a class Finch exports from the other image is listed
as misplaced. Private names (leading underscores) and Swift symbols are not counted.

Prints, per framework, the counts and the missing public classes; -v also
lists missing functions and variables. Reads the SDK at run time only; no
Apple file is copied.
"""
import os
import re
import subprocess
import sys

FINCH_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAMEWORKS = os.path.join(FINCH_ROOT, "build/root/System/Library/Frameworks")


def sdk_path():
    return subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()


def tbd_exports(name):
    """(classes, symbols) Apple's tbd lists for arm64e macOS, re-exports aside."""
    path = os.path.join(sdk_path(), "System/Library/Frameworks", f"{name}.framework", f"{name}.tbd")
    text = open(path).read()
    # Only the main document (the first "--- !tapi-tbd" block); later ones are re-exported libraries.
    docs = re.split(r"\n--- !tapi-tbd", text)
    doc = docs[0]
    classes, symbols = set(), set()
    for block in re.finditer(r"- targets:\s*\[([^\]]*)\]\s*\n((?:\s{4,}.*\n?)+)", doc):
        targets = block.group(1)
        if "arm64e-macos" not in targets and "arm64-macos" not in targets:
            continue
        body = block.group(2)
        for kind, items in re.findall(r"(objc-classes|symbols|weak-symbols):\s*\[([^\]]*)\]", body, re.S):
            names = [n.strip().strip("'\"") for n in items.replace("\n", " ").split(",")]
            for n in names:
                if not n:
                    continue
                (classes if kind == "objc-classes" else symbols).add(n)
    return classes, symbols


def finch_exports(name):
    binary = os.path.join(FRAMEWORKS, f"{name}.framework", name)
    if not os.path.exists(binary):
        return None, None
    out = subprocess.run(["nm", "-gU", "-arch", "arm64e", binary], capture_output=True, text=True).stdout
    classes, symbols = set(), set()
    for line in out.splitlines():
        sym = line.split()[-1]
        if sym.startswith("_OBJC_CLASS_$_"):
            classes.add(sym[len("_OBJC_CLASS_$_"):])
        elif not sym.startswith(("_OBJC_METACLASS_$_", "_OBJC_IVAR_$_")):
            symbols.add(sym)
    return classes, symbols


def public_class(n):
    return not n.startswith("_")


def public_symbol(n):
    """C functions and variables: "_NSLog", not Swift ("_$s...") or "__private"."""
    return n.startswith("_") and not n.startswith(("__", "_$s", "_$S", "_OBJC_", "_symbolic", "_associated"))


def main(argv):
    verbose = "-v" in argv
    names = [a for a in argv if not a.startswith("-")] or ["CoreFoundation", "Foundation"]
    finch = {n: finch_exports(n) for n in names}
    # Foundation re-exports CoreFoundation, so what Apple's Foundation exports
    # may come from Finch's CoreFoundation too (not the other way round).
    reexported = {"Foundation": ["CoreFoundation"]}
    for name in names:
        apple_classes, apple_symbols = tbd_exports(name)
        ours_classes, ours_symbols = finch[name]
        if ours_classes is None:
            print(f"{name}: not built")
            continue
        for sub in reexported.get(name, []):
            sub_classes, sub_symbols = finch.get(sub) or finch_exports(sub)
            if sub_classes:
                ours_classes = ours_classes | sub_classes
                ours_symbols = ours_symbols | sub_symbols
        apple_classes = {c for c in apple_classes if public_class(c)}
        apple_symbols = {s for s in apple_symbols if public_symbol(s)}
        missing = sorted(apple_classes - ours_classes)
        elsewhere = {c: o for c in missing for o, (oc, _) in finch.items() if o != name and oc and c in oc}
        missing_syms = sorted(apple_symbols - ours_symbols)
        print(f"{name}: classes {len(apple_classes & ours_classes)}/{len(apple_classes)}, "
              f"other symbols {len(apple_symbols & ours_symbols)}/{len(apple_symbols)}")
        if elsewhere:
            print("  misplaced (Apple's is here, Finch's is in another image): " +
                  " ".join(f"{c}({o})" for c, o in sorted(elsewhere.items())))
        absent = [c for c in missing if c not in elsewhere]
        if absent:
            print("  missing classes: " + " ".join(absent))
        if verbose and missing_syms:
            print("  missing symbols: " + " ".join(missing_syms))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
