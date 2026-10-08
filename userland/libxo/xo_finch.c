/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * xo_error_hv(): the handle-taking va_list form of xo_error(), which Apple's
 * libxo 1.6.0 exports and upstream 1.6.0 lacks (later upstream releases
 * define it the same way: xo_errorn_hv() without a forced newline).
 */
#include <stdarg.h>

typedef struct xo_handle_s xo_handle_t;
void xo_errorn_hv(xo_handle_t *xop, int need_newline, const char *fmt, va_list vap);
void xo_error_hv(xo_handle_t *xop, const char *fmt, va_list vap);

void
xo_error_hv(xo_handle_t *xop, const char *fmt, va_list vap)
{
    xo_errorn_hv(xop, 0, fmt, vap);
}
