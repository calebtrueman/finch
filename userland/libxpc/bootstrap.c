/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * bootstrap_* (Mach service registry client). On macOS these live in libxpc
 * and talk to launchd. In Finch they'll talk to finch-init (step X4,
 * docs/design/XPC.md). Until then, every name is unknown.
 */

#include <servers/bootstrap.h>

#include "internal.h"

kern_return_t
bootstrap_look_up(mach_port_t bp, const name_t service_name, mach_port_t *sp)
{
	(void)bp; (void)service_name;
	*sp = MACH_PORT_NULL;
	return BOOTSTRAP_UNKNOWN_SERVICE;
}

kern_return_t
bootstrap_check_in(mach_port_t bp, const name_t service_name, mach_port_t *sp)
{
	(void)bp; (void)service_name;
	*sp = MACH_PORT_NULL;
	return BOOTSTRAP_UNKNOWN_SERVICE;
}
