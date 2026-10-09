// SPDX-License-Identifier: MIT OR Apache-2.0
// What swift-foundation (FOUNDATION_FRAMEWORK) uses of libquarantine's
// private API. Finch has no quarantine (Gatekeeper) yet: no file carries a
// quarantine record, so _qtn_file_alloc reports none.
#pragma once
#include <stdint.h>
#include <stddef.h>
typedef struct _qtn_file_s *_qtn_file_t;
enum qtn_flags : uint32_t {
    QTN_FLAG_DOWNLOAD = 0x0001,
    QTN_FLAG_SANDBOX = 0x0002,
    QTN_FLAG_HARD = 0x0004,
    QTN_FLAG_USER_APPROVED = 0x0040,
    QTN_FLAG_DO_NOT_TRANSLOCATE = 0x0100,
};
static inline _qtn_file_t _Nullable _qtn_file_alloc(void) { return NULL; }
static inline void _qtn_file_free(_qtn_file_t _Nonnull qf) {}
static inline int _qtn_file_init_with_path(_qtn_file_t _Nonnull qf, const char * _Nonnull path) { return -1; }
static inline uint32_t _qtn_file_get_flags(_qtn_file_t _Nonnull qf) { return 0; }
static inline int _qtn_file_set_flags(_qtn_file_t _Nonnull qf, uint32_t flags) { return -1; }
static inline int _qtn_file_apply_to_path(_qtn_file_t _Nonnull qf, const char * _Nonnull path) { return -1; }
