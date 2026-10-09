#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Security.framework (docs/design/SECURITY.md): Finch's own implementation,
# with what it takes from Apple's open-source Security (pinned in
# userland/projects.txt):
#   - the public kSec... constants, with the values Apple's source defines
#     (gen-constants.py)
#   - Resources/en.lproj/SecErrorMessages.strings, made by Apple's
#     generateErrStrings.pl from the SDK's headers, for SecCopyErrorMessageString
#   - Resources/authorization.plist, Apple's authorization rights database
# Certificates, keys, trust and CMS use OpenSSL 3.5.9, from Finch's corecrypto
# build (build/obj/corecrypto-openssl), linked statically with its symbols hidden.
#
# Linked as Apple ships it: install name, current version 61901.100.255.
#   FINCH_OUTPUT_ROOT / FINCH_OBJ_DIR override build/root and build/obj/Security.
#
#   userland/Security/build.sh -> build/root/System/Library/Frameworks/Security.framework
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$FINCH_ROOT/userland/Security"
SRC="$FINCH_ROOT/build/src/Security"
OBJ="${FINCH_OBJ_DIR:-$FINCH_ROOT/build/obj/Security}"
ROOT="${FINCH_OUTPUT_ROOT:-$FINCH_ROOT/build/root}"
FW="$ROOT/System/Library/Frameworks/Security.framework"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
SDKH="$SDKROOT/System/Library/Frameworks/Security.framework/Headers"
OPENSSL="$FINCH_ROOT/build/obj/corecrypto-openssl"
CC="$(xcrun -f clang)"
log() { echo "==> $*"; }

[[ -d "$SRC" ]] || { echo "missing Security (tools/fetch-src.sh Security)" >&2; exit 1; }
[[ -f "$OPENSSL/libcrypto.a" ]] || { echo "build corecrypto first (make -C userland/corecrypto install)" >&2; exit 1; }
[[ -f "$FINCH_ROOT/build/root/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" ]] \
    || { echo "build CoreFoundation first (userland/CoreFoundation/build.sh)" >&2; exit 1; }

log "generating constants and error strings"
rm -rf "$OBJ" && mkdir -p "$OBJ/hdr/CoreFoundation" "$OBJ/o" "$OBJ/res/en.lproj"
sed -E 's/#include "(CF[^"]+)"/#include <CoreFoundation\/\1>/' \
    "$FINCH_ROOT/build/src/swift-corelibs-foundation/Sources/CoreFoundation/include/CFRuntime.h" > "$OBJ/hdr/CoreFoundation/CFRuntime.h"
python3 "$HERE/gen-constants.py" "$SRC" "$SDKH" "$OBJ/SecConstants.c"
perl "$SRC/OSX/lib/generateErrStrings.pl" NO "$OBJ/res" "$OBJ/res/en.lproj/SecErrorMessages.strings" \
    "$SDKH/Authorization.h" "$SDKH/AuthSession.h" "$SDKH/SecureTransport.h" "$SDKH/SecBase.h" \
    "$SDKH/cssmerr.h" "$SDKH/cssmapple.h" "$SDKH/CSCommon.h" \
    "$SRC/OSX/libsecurity_keychain/lib/MacOSErrorStrings.h" > /dev/null

CFLAGS=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "$SDKROOT" -Os -g -fblocks -fno-common
    -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations -Wno-nonnull
    -I"$HERE" -I"$OBJ/hdr" -I"$OPENSSL/include" -I"$FINCH_ROOT/build/src/openssl/include")

log "compiling"
objects=()
for source in "$HERE"/*.c "$OBJ/SecConstants.c"; do
    output="$OBJ/o/$(basename "${source%.c}").o"
    "$CC" "${CFLAGS[@]}" -c "$source" -o "$output"
    objects+=("$output")
done

log "linking"
mkdir -p "$FW/Versions/A/Resources/en.lproj"
"$CC" -arch arm64e -mmacosx-version-min=26.0 -isysroot "$SDKROOT" -dynamiclib \
    -install_name /System/Library/Frameworks/Security.framework/Versions/A/Security \
    -current_version 61901.100.255 -compatibility_version 1 \
    "${objects[@]}" "$OPENSSL/libcrypto.a" \
    -F"$FINCH_ROOT/build/root/System/Library/Frameworks" -framework CoreFoundation -lbsm \
    -Wl,-exported_symbols_list,"$HERE/exports.txt" -Wl,-no_warn_inits \
    -o "$FW/Versions/A/Security"
ln -sfn A "$FW/Versions/Current"
ln -sfn Versions/Current/Security "$FW/Security"
"$FINCH_ROOT/tools/mkframeworkplist.sh" "$FW" A Security com.apple.security Security 7.0 61901.101.4 English
cp "$OBJ/res/en.lproj/SecErrorMessages.strings" "$FW/Versions/A/Resources/en.lproj/"
cp "$SRC/OSX/authd/authorization.plist" "$FW/Versions/A/Resources/"
codesign -f -s - -i com.apple.security "$FW/Versions/A/Security" 2>/dev/null

# Notices: Apple's (APSL) for the data taken from Security; OpenSSL's for the
# code linked in.
LIC="$ROOT/usr/share/finch/licenses/Security"
mkdir -p "$LIC"
cp "$SRC/OSX/APPLE_LICENSE" "$LIC/APPLE_LICENSE"
cp "$FINCH_ROOT/build/src/openssl/LICENSE.txt" "$LIC/OpenSSL-LICENSE.txt"
log "installed ${FW#"$FINCH_ROOT/"}"
