/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#ifndef FINCH_HE_TEST_SYMBOL_OWNER_H
#define FINCH_HE_TEST_SYMBOL_OWNER_H
#include <limits.h>
static void *finch_test_local_handle;
static char finch_test_local_path[PATH_MAX];
static void finch_test_set_local(void *handle, const char *path)
{
	finch_test_local_handle = handle;
	if (!realpath(path, finch_test_local_path)) {
		perror(path);
		exit(1);
	}
}
static void *finch_test_dlsym(void *handle, const char *name)
{
	void *symbol = dlsym(handle, name);
	if (!symbol) {
		fprintf(stderr, "Missing function %s: %s\n", name, dlerror());
		exit(1);
	}
	if (handle == finch_test_local_handle) {
		Dl_info owner;
		char path[PATH_MAX];
		if (!dladdr(symbol, &owner) || !realpath(owner.dli_fname, path) ||
		    strcmp(path, finch_test_local_path)) {
			fprintf(stderr, "%s did not come from the library under test\n", name);
			exit(1);
		}
	}
	return symbol;
}
#define dlsym finch_test_dlsym
#endif
