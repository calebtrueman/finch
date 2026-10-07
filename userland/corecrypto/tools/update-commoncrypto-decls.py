#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Refresh CommonCrypto declarations from Finch's own C implementations.

This reads only Finch's sources and the published CommonCrypto client sources.
It never reads Apple's corecrypto reference sources. Handwritten storage and
macro definitions remain in compat/corecrypto/finch_compat.h.
"""
import concurrent.futures
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
ABI = ROOT / "userland/corecrypto/abi"
COMMON = ROOT / "build/src/CommonCrypto/lib"
text = "\n".join(p.read_text() for p in COMMON.glob("*.[ch]"))
used = set(re.findall(r"\bcc\w+", text))


def declarations(path):
    command = ["xcrun", "clang", "-arch", "arm64e", "-Wno-everything",
               "-I" + str(ROOT / "userland/corecrypto/include"),
               "-I" + str(ROOT / "build/obj/corecrypto-openssl/include"),
               "-I" + str(ROOT / "build/src/openssl/include"),
               "-Xclang", "-ast-dump=json", "-fsyntax-only", str(path)]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    found = {}
    for node in json.loads(result.stdout).get("inner", []):
        if (node.get("kind") != "FunctionDecl" or node.get("name") not in used
                or node.get("storageClass") == "static"):
            continue
        if not any(child.get("kind") == "CompoundStmt" for child in node.get("inner", [])):
            continue
        name, signature = node["name"], node["type"]["qualType"]
        at = signature.index("(")
        found[name] = signature[:at] + name + signature[at:] + ";"
    return found


if __name__ == "__main__":
    found = {}
    makefile = (ROOT / "userland/corecrypto/Makefile").read_text()
    sources = sorted(set(re.findall(r"abi/([A-Za-z0-9_]+\.c)", makefile)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for result in pool.map(declarations, [ABI / name for name in sources]):
            found.update(result)
    destination = ROOT / "userland/corecrypto/compat/corecrypto/finch_decls.h"
    destination.write_text("/* SPDX-License-Identifier: MIT OR Apache-2.0 */\n"
                           "/* Generated from Finch implementations by tools/update-commoncrypto-decls.py. */\n"
                           + "\n".join(found[name] for name in sorted(found)) + "\n")
    print(f"Updated {len(found)} declarations in {destination}")
