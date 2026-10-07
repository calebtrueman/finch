/* SPDX-License-Identifier: MIT OR Apache-2.0 */
#include "internal.h"
#include <errno.h>
#include <string.h>
extern int __sandbox_ms(const char *, int, void *);
API int amfi_check_dyld_policy_self(uint64_t flags, uint64_t *out)
{
	if (!out)
		return EINVAL;
	*out = 0;
	uint64_t result = UINT64_C(0xaaaaaaaaaaaaaaaa);
	struct {
		uint64_t flags;
		uint64_t *result;
	} request = {flags, &result};
	int rc = __sandbox_ms("AMFI", 90, &request);
	if (rc)
		rc = errno;
	*out = result;
	return rc;
}
API int amfi_check_dyld_policy_for_pid(int pid, uint64_t flags, uint64_t *out)
{
	if (!out)
		return EINVAL;
	*out = 0;
	uint64_t result = UINT64_C(0xaaaaaaaaaaaaaaaa);
	struct {
		uint64_t flags;
		uint64_t *result;
		int pid;
		uint32_t pad;
	} request = {flags, &result, pid, 0xaaaaaaaa};
	int rc = __sandbox_ms("AMFI", 91, &request);
	if (rc)
		rc = errno;
	*out = result;
	return rc;
}
API int amfi_load_trust_cache(uint8_t type, const void *payload, uint32_t size,
    const void *manifest, uint32_t manifest_size, void *result, uint32_t flags)
{
	struct {
		uint8_t type, pad[7];
		const void *payload;
		uint32_t size, pad2;
		const void *manifest;
		uint32_t manifest_size, pad3;
		void *result;
		uint32_t flags, pad4;
	} request;
	memset(&request, 0xaa, sizeof(request));
	request.type = type;
	request.payload = payload;
	request.size = size;
	request.manifest = manifest;
	request.manifest_size = manifest_size;
	request.result = result;
	request.flags = flags;
	return __sandbox_ms("AMFI", 101, &request);
}
API int amfi_unload_trust_cache(uint64_t handle)
{
	return __sandbox_ms("AMFI", 105, &handle);
}
