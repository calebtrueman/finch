/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "finch_compat.h"

/* GCM sizes, as corecrypto's <corecrypto/ccmode.h> defines them (IOKit's
 * IOHibernatePrivate.h uses them): a 96-bit IV and the 128-bit block/tag. */
#ifndef CCGCM_IV_NBYTES
#define CCGCM_IV_NBYTES     12
#endif
#ifndef CCGCM_BLOCK_NBYTES
#define CCGCM_BLOCK_NBYTES  16
#endif
