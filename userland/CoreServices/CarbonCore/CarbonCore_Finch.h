/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/* Shared by Finch's CoreServices subframeworks (userland/CoreServices). */
#ifndef CARBONCORE_FINCH_H
#define CARBONCORE_FINCH_H

#include <CoreServices/CoreServices.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define FINCH_HIDDEN __attribute__((visibility("hidden")))
/* Finch's own cross-subframework calls; exported, never declared by the SDK. */
#define FINCH_EXPORT __attribute__((visibility("default")))

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* Seconds between the Mac epoch (1904) and the Unix one (1970). */
#define FINCH_MAC_EPOCH_DELTA 2082844800LL

#endif
