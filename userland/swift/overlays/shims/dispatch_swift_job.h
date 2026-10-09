// SPDX-License-Identifier: MIT OR Apache-2.0
// The one function the Dispatch overlay uses from libdispatch's
// private/queue_private.h (which needs the internal SDK's headers),
// declared as libdispatch declares it.
#pragma once
#include <dispatch/dispatch.h>
DISPATCH_EXPORT DISPATCH_NONNULL1 DISPATCH_NONNULL2 DISPATCH_REFINED_FOR_SWIFT
void dispatch_async_swift_job(dispatch_queue_t _Nonnull queue, void * _Nonnull swift_job,
    dispatch_qos_class_t qos);
