/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-dlopen: dlopen() each path given and report dlerror() for failures,
 * to diagnose plug-ins (PAM modules, bundles) that fail to load.
 */
#include <dlfcn.h>
#include <stdio.h>

int
main(int argc, char **argv)
{
	int failures = 0;
	for (int i = 1; i < argc; i++) {
		void *h = dlopen(argv[i], RTLD_NOW | RTLD_LOCAL);
		printf("%s: %s\n", argv[i], h ? "ok" : dlerror());
		failures += h == NULL;
	}
	return failures != 0;
}
