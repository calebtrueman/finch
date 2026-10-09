#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# finch-assets-test: run AssetsTest.app's executable (assets-test.m), which reads its own bundle's catalogs.
exec /Applications/AssetsTest.app/Contents/MacOS/finch-assets-test "$@"
