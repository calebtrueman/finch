/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CoreAnalytics: apps report usage events here. Finch collects none: no
 * event is "used", and events sent are dropped (their builders aren't run).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

bool AnalyticsIsEventUsed(CFStringRef eventName);
void AnalyticsSendEvent(CFStringRef eventName, CFDictionaryRef payload);
void AnalyticsSendEventLazy(CFStringRef eventName, CFDictionaryRef (^builder)(void));
void AnalyticsSendExplicitEvent(CFStringRef eventName, CFDictionaryRef payload);

bool AnalyticsIsEventUsed(CFStringRef eventName) { return false; }
void AnalyticsSendEvent(CFStringRef eventName, CFDictionaryRef payload) {}
void AnalyticsSendEventLazy(CFStringRef eventName, CFDictionaryRef (^builder)(void)) {}
void AnalyticsSendExplicitEvent(CFStringRef eventName, CFDictionaryRef payload) {}
