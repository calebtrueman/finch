#!/bin/sh
# SPDX-License-Identifier: MIT OR Apache-2.0
# Drive Hello.app on a headless window server (finch-app-test); compare with hello-test.expected.
#   hello-test.sh [finch-app-test] [finch-windowserver] [Hello executable]
TEST="${1:-/usr/local/bin/finch-app-test}"
SERVER="${2:-/usr/libexec/finch-windowserver}"
APP="${3:-/Applications/Hello.app/Contents/MacOS/Hello}"
exec "$TEST" "$SERVER" "$APP" "window:Hello, Finch" wait:1500 windows output sample:5,40,content sample:180,16,titlebar \
    click:222,68 type:Finch click:111,99 click:298,132 output sample:298,132,button cmd:q output 2>/dev/null
