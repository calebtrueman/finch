// SPDX-License-Identifier: MIT OR Apache-2.0
// The container manager call swift-foundation's FileManager makes for app
// group containers. Finch has no container manager: there are no app group
// containers.
#pragma once
#include <stdint.h>
#include <stddef.h>
static inline char * _Nullable container_create_or_lookup_app_group_path_by_app_group_identifier(
    const char * _Nonnull identifier, uint64_t * _Nullable error) {
    if (error) *error = 1;
    return NULL;
}
