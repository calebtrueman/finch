/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <EndpointSecuritySystem/ESSubmitSPI.h>: event submission SPI exported by
 * libEndpointSecuritySystem (Apple doesn't publish the header). Only the
 * calls login(1) makes, with the arguments it passes; callers weak-link them.
 */
#ifndef _ESSUBMITSPI_H_
#define _ESSUBMITSPI_H_

#include <stdbool.h>
#include <sys/cdefs.h>
#include <sys/types.h>

__BEGIN_DECLS

/* A login attempt: on failure, failure_message says why; uid may be NULL. */
void ess_notify_login_login(bool success, const char *failure_message, const char *username,
    const uid_t *uid);
void ess_notify_login_logout(const char *username, uid_t uid);

__END_DECLS

#endif /* !_ESSUBMITSPI_H_ */
