#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Write a framework's Resources/Info.plist, with the keys Apple's frameworks
# carry, so CFBundle and NSBundle identify it as macOS does (bundle
# identifier, executable, versions).
#
#   tools/mkframeworkplist.sh <Foo.framework> <version dir> <executable> <identifier> \
#       <name> <short version> <bundle version> <development region>
set -euo pipefail
fw="$1"; ver="$2"; exe="$3"; id="$4"; name="$5"; short="$6"; version="$7"; region="$8"
res="${fw}/Versions/${ver}/Resources"
mkdir -p "${res}"
plist="${res}/Info.plist"
rm -f "${plist}"
plutil -create xml1 "${plist}"
plutil -insert CFBundleDevelopmentRegion -string "${region}" "${plist}"
plutil -insert CFBundleExecutable -string "${exe}" "${plist}"
plutil -insert CFBundleIdentifier -string "${id}" "${plist}"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "${plist}"
plutil -insert CFBundleName -string "${name}" "${plist}"
plutil -insert CFBundlePackageType -string FMWK "${plist}"
plutil -insert CFBundleShortVersionString -string "${short}" "${plist}"
plutil -insert CFBundleSignature -string "????" "${plist}"
[[ -z "${version}" ]] || plutil -insert CFBundleVersion -string "${version}" "${plist}"
ln -sfn "Versions/Current/Resources" "${fw}/Resources"
