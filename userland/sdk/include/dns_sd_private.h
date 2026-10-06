/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * <dns_sd_private.h>: the parts of mDNSResponder's private DNS-SD interface
 * that Libinfo uses beyond the public <dns_sd.h>. The symbols are exported by
 * libsystem_dnssd.
 */

#ifndef _DNS_SD_PRIVATE_H
#define _DNS_SD_PRIVATE_H

#include <dns_sd.h>

__BEGIN_DECLS

/* Query attribute: allow DNS push/failover to another resolver. */
extern const DNSServiceAttribute kDNSServiceAttrAllowFailover;

__END_DECLS

#endif
