/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "internal.h"
#include <pthread.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
static pthread_once_t storage_once = PTHREAD_ONCE_INIT;
static bool storage_available;
static void check_storage(void)
{
	char arguments[1024] = {0};
	size_t size = sizeof(arguments);
	if (!sysctlbyname("kern.bootargs", arguments, &size, NULL, 0)) {
		arguments[sizeof(arguments) - 1] = 0;
		if (strcasestr(arguments, "libtrace_full_db=0"))
			return;
		if (strcasestr(arguments, "bs_var_db_extra=") ||
		    strcasestr(arguments, "libtrace_full_db")) {
			storage_available = true;
			return;
		}
	}
	struct stat status;
	if (!lstat("/private/var/db/diagnostics", &status) && S_ISLNK(status.st_mode))
		storage_available = true;
}
API bool _os_trace_basesystem_storage_available(void)
{
	pthread_once(&storage_once, check_storage);
	return storage_available;
}
