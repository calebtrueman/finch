#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
"""Print 'domain feature' for every feature in the host's FeatureFlags plists."""
import os
import plistlib

BASE = "/System/Library/FeatureFlags"
seen = set()


def emit(dom, feat):
    if (dom, feat) not in seen and " " not in dom + feat:
        seen.add((dom, feat))
        print(dom, feat)


for sub in ("Domain", "Unified/Domain"):
    d = os.path.join(BASE, sub)
    for f in sorted(os.listdir(d)):
        if f.endswith(".plist"):
            try:
                for feat in plistlib.load(open(os.path.join(d, f), "rb")):
                    emit(f[:-6], feat)
            except Exception:
                pass
for dom, feats in plistlib.load(open(os.path.join(BASE, "Global.plist"), "rb")).items():
    for feat in feats:
        emit(dom, feat)
emit("libmalloc", "NoSuchFeatureXYZ")
emit("NoSuchDomainXYZ", "Feature")
