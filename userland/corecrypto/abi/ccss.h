/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_ABI_CCSS_H
#define FINCH_ABI_CCSS_H
#include "cczp.h"
#include "ccrng.h"
#include <stdbool.h>
struct ccss_parameters {
	uint32_t threshold, reserved;
	struct cczp prime;
};
struct ccss_value {
	const struct cczp *prime;
	uint32_t index, reserved;
	cc_unit data[];
};
struct ccss_bag {
	const struct ccss_parameters *parameters;
	uint32_t count, reserved;
	cc_unit data[];
};
#endif
