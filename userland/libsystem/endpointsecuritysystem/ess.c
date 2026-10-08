/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libEndpointSecuritySystem: how system components report security events
 * (logins, su, authorization) to the EndpointSecurity subsystem, for security
 * tools subscribed to it. Apple's is closed. Finch has no EndpointSecurity
 * subsystem yet, so nothing subscribes; instead of dropping the events, Finch
 * records each in the unified log (subsystem com.apple.endpointsecurity,
 * category submit), where `log show` finds them.
 *
 * Only the calls Finch's binaries make are here (login(1)'s), with the
 * arguments they pass (<EndpointSecuritySystem/ESSubmitSPI.h>); the rest of
 * Apple's 43 come as something imports them. Callers weak-link these.
 */

#include <EndpointSecuritySystem/ESSubmitSPI.h>
#include <os/log.h>

static os_log_t
ess_log(void)
{
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.apple.endpointsecurity", "submit"); });
    return log;
}

void
ess_notify_login_login(bool success, const char *failure_message, const char *username, const uid_t *uid)
{
    if (success) {
        os_log(ess_log(), "login: %{public}s (uid %d) logged in", username ? username : "?",
            uid ? (int)*uid : -1);
    } else {
        os_log_error(ess_log(), "login: %{public}s failed: %{public}s", username ? username : "?",
            failure_message ? failure_message : "unknown reason");
    }
}

void
ess_notify_login_logout(const char *username, uid_t uid)
{
    os_log(ess_log(), "login: %{public}s (uid %d) logged out", username ? username : "?", (int)uid);
}
