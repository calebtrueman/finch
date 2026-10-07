/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * libsystem_darwindirectory: Apple's local user/group record store, which
 * Libinfo consults when its Darwin Directory feature flag is on. Finch's
 * Libinfo is built without it (users and groups come from /etc files), and
 * this store holds no records: appliers are never called, and the
 * generation never changes. Signatures from Libinfo-600's
 * darwin_directory_helpers.h.
 */

#include <stdbool.h>
#include <stdint.h>

typedef void *darwin_directory_record_t;
typedef void (^darwin_directory_applier_t)(darwin_directory_record_t record, bool *stop);

uint16_t DarwinDirectoryGetGeneration(void);
void DarwinDirectoryRecordStoreApply(int type, darwin_directory_applier_t applier);
void DarwinDirectoryRecordStoreApplyWithFilter(int type, const void *filter, darwin_directory_applier_t applier);

uint16_t
DarwinDirectoryGetGeneration(void)
{
	return 0;
}

void
DarwinDirectoryRecordStoreApply(int type, darwin_directory_applier_t applier)
{
	(void)type; (void)applier;
}

void
DarwinDirectoryRecordStoreApplyWithFilter(int type, const void *filter, darwin_directory_applier_t applier)
{
	(void)type; (void)filter; (void)applier;
}
