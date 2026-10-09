#!/bin/bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# Build recipe for libxml2-39.10: /usr/lib/libxml2.2.dylib, which Foundation's
# NSXMLParser is built on (docs/design/FOUNDATION.md). Called by
# tools/build-oss.sh (SRC, OBJ, STAGE, SDKROOT, FINCH_SDK_CFLAGS).
#
# Compiles the sources of the project's xml2 target with its settings
# (Apple's pregenerated config.h and xmlversion.h), then links them as its
# libxml2 target does: version 10.9.0, compatibility 10.0.0, Apple's export
# list (Pregenerated Files/libxml2.exp), libicucore and libz. (Xcode's own
# build of the project stalls scanning dependencies, so it isn't used.)
# ICU's headers, which Apple's internal SDK has, come from Finch's ICU build.
set -euo pipefail
FINCH_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SDK="${FINCH_ROOT}/build/sdk"
ICU_HEADERS="${FINCH_ROOT}/build/root/usr/local/include"
[[ -f "${ICU_HEADERS}/unicode/ucnv.h" ]] || { echo "build ICU first: tools/build-oss.sh ICU" >&2; exit 1; }
cd "${SRC}"
rm -rf "${OBJ}"; mkdir -p "${OBJ}/icu" "${STAGE}/usr/lib"
# Just ICU's headers (the directory has Libc's and others too).
ln -s "${ICU_HEADERS}/unicode" "${OBJ}/icu/unicode"

CC="xcrun -sdk macosx clang"
flags=(-arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -Os -std=gnu99 -fvisibility=default
       -DHAVE_CONFIG_H -DNDEBUG -DLIBXML_STATIC
       -I"Pregenerated Files/include" -Ilibxml2/include -Ilibxml2 -isystem "${OBJ}/icu"
       -include "${FINCH_ROOT}/userland/oss/libxml2.prelude.h" -idirafter "${SDK}/override" -idirafter "${SDK}/availability"
       ${FINCH_SDK_CFLAGS} -ftrivial-auto-var-init=zero -w)
objs=()
for f in buf c14n catalog chvalid debugXML dict DOCBparser encoding entities error globals hash HTMLparser \
         HTMLtree legacy list nanoftp nanohttp parser parserInternals pattern relaxng SAX SAX2 schematron \
         threads tree uri valid xinclude xlink xmlIO xmlmemory xmlmodule xmlreader xmlregexp xmlsave \
         xmlschemas xmlschemastypes xmlstring xmlunicode xmlversion xmlwriter xpath xpointer xzlib; do
    ${CC} "${flags[@]}" -c "libxml2/$f.c" -o "${OBJ}/$f.o"
    objs+=("${OBJ}/$f.o")
done

${CC} -arch arm64e -mmacosx-version-min=26.0 -isysroot "${SDKROOT}" -dynamiclib \
    -install_name /usr/lib/libxml2.2.dylib -current_version 10.9.0 -compatibility_version 10.0.0 \
    -Wl,-exported_symbols_list,"Pregenerated Files/libxml2.exp" \
    "${objs[@]}" -licucore -lz -o "${STAGE}/usr/lib/libxml2.2.dylib"
ln -sfn libxml2.2.dylib "${STAGE}/usr/lib/libxml2.dylib"
echo "linked libxml2.2.dylib from ${#objs[@]} objects"
