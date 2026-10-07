/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * Differential test: for every feature named in the macOS install's
 * FeatureFlags plists, ask Apple's libsystem_featureflags and Finch's and
 * compare both answers (os_feature_enabled, and _simple with each default).
 *
 *   ff-compare <finch libsystem_featureflags.dylib>   (lines on stdin: domain feature)
 */
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

bool _os_feature_enabled_impl(const char *domain, const char *feature);
bool _os_feature_enabled_simple_impl(const char *domain, const char *feature, bool fallback);

int
main(int argc, char **argv)
{
	void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
	if (!h) { fprintf(stderr, "%s\n", dlerror()); return 2; }
	bool (*ours)(const char *, const char *) = dlsym(h, "_os_feature_enabled_impl");
	bool (*ours_s)(const char *, const char *, bool) = dlsym(h, "_os_feature_enabled_simple_impl");
	char d[256], f[256];
	int n = 0, bad = 0, on = 0;
	while (scanf("%255s %255s", d, f) == 2) {
		bool a = _os_feature_enabled_impl(d, f), b = ours(d, f);
		bool a1 = _os_feature_enabled_simple_impl(d, f, true), b1 = ours_s(d, f, true);
		bool a0 = _os_feature_enabled_simple_impl(d, f, false), b0 = ours_s(d, f, false);
		n++;
		on += a;
		if (a != b || a1 != b1 || a0 != b0) {
			bad++;
			if (bad <= 15) printf("DIFF %s/%s apple=%d/%d/%d finch=%d/%d/%d\n", d, f, a, a1, a0, b, b1, b0);
		}
	}
	printf("%s: %d features compared (%d enabled), %d differ\n", bad ? "FAILED" : "PASSED", n, on, bad);
	return bad != 0;
}
