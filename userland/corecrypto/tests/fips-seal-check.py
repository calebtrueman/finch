#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Check seal changes on copies, without loading changed executable code."""
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("seal_corecrypto", Path(__file__).resolve().parents[1] / "tools" / "seal-corecrypto.py")
seal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seal)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: fips-seal-check.py sealed-arm64e-dylib")
    original = Path(sys.argv[1]).read_bytes()
    assert seal.verify(original), "the input image must have a valid seal"
    sections = seal.text_sections(original)
    digest, offset = seal.image_digest(original)
    checks = 1
    with tempfile.TemporaryDirectory(prefix="finch-seal-test-") as directory:
        for section_name in ("__text", "__const"):
            sections_with_name = [(start, size) for name, start, size in sections if name == section_name and size]
            assert sections_with_name, f"expected a nonempty {section_name} section"
            start, size = sections_with_name[0]
            changed = bytearray(original)
            changed[start + size // 2] ^= 1
            copy = Path(directory) / f"changed-{section_name}.dylib"
            copy.write_bytes(changed)
            assert not seal.verify(copy.read_bytes()), f"a changed {section_name} byte went undetected"
            checks += 1
        unsealed = bytearray(original)
        unsealed[offset:offset + 32] = bytes(32)
        copy = Path(directory) / "unsealed.dylib"
        copy.write_bytes(unsealed)
        assert not seal.verify(copy.read_bytes()), "an empty seal was accepted"
        checks += 1
        unsealed[offset:offset + 32] = digest
        assert seal.verify(unsealed), "restoring a seal did not restore verification"
        checks += 1
        bad_seal = bytearray(original)
        bad_seal[offset] ^= 1
        assert not seal.verify(bad_seal), "a changed seal was accepted"
        checks += 1
        no_section = bytearray(original)
        command_bytes = struct.unpack_from("<I", original, 20)[0]
        name_at = no_section.find(b"__finch_seal\0", 32, 32 + command_bytes)
        assert name_at >= 0
        no_section[name_at] = ord("X")
        try:
            seal.image_digest(no_section)
        except ValueError:
            checks += 1
        else:
            raise AssertionError("an image without a seal section was accepted")
        for truncated in (b"", original[:31], original[:64]):
            try:
                seal.image_digest(truncated)
            except ValueError:
                checks += 1
            else:
                raise AssertionError("a truncated file was accepted")
    print(f"Finch image seal: {checks} checks passed; changed code was never loaded")


if __name__ == "__main__":
    main()
