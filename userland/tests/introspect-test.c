/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * finch-introspect-test: libdyld's process introspection, on this process
 * (or on the pid given): process, snapshot, shared cache, images. gcore and
 * the symbolication tools rely on it.
 */
#include <errno.h>
#include <mach/mach.h>
#include <mach-o/dyld_images.h>
#include <mach-o/dyld_introspection.h>
#include <stdio.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/fsgetpath.h>
#include <stdlib.h>
#include <uuid/uuid.h>

kern_return_t task_read_for_pid(mach_port_t target, int pid, task_read_t *t);

/*
 * What libdyld's FileManager needs to find files again from a snapshot: the
 * root volume's UUID and persistent object IDs, and fsgetpath.
 */
static void
report_volume(const char *path)
{
	struct {
		uint32_t length;
		vol_capabilities_attr_t caps;
		uuid_t uuid;
	} __attribute__((aligned(4), packed)) buf;
	struct attrlist al = { .bitmapcount = ATTR_BIT_MAP_COUNT,
		.volattr = ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES | ATTR_VOL_UUID };
	struct statfs sf;
	struct stat st;
	uuid_string_t s;
	char back[PATH_MAX];

	if (statfs(path, &sf) != 0 || stat(path, &st) != 0) {
		printf("volume: %s: %s\n", path, strerror(errno));
		return;
	}
	if (getattrlist(sf.f_mntonname, &al, &buf, sizeof(buf), 0) != 0) {
		printf("volume: getattrlist %s: %s\n", sf.f_mntonname, strerror(errno));
		return;
	}
	uuid_unparse(buf.uuid, s);
	printf("volume: %s on %s (%s%s), uuid %s, persistent ids %s\n", path, sf.f_mntonname,
	    sf.f_fstypename, (sf.f_flags & MNT_ROOTFS) ? ", root" : "", s,
	    (buf.caps.capabilities[VOL_CAPABILITIES_FORMAT] & VOL_CAP_FMT_PERSISTENTOBJECTIDS) ? "yes" : "NO");
	ssize_t n = fsgetpath(back, sizeof(back), &sf.f_fsid, st.st_ino);
	printf("volume: fsgetpath(%#llx) = %s\n", (unsigned long long)st.st_ino, n < 0 ? strerror(errno) : back);
}

int
main(int argc, char **argv)
{
	task_read_t task = mach_task_self();
	kern_return_t kr = KERN_SUCCESS;
	int failures = 0;

	if (argc > 1 && (kr = task_read_for_pid(mach_task_self(), atoi(argv[1]), &task)) != KERN_SUCCESS) {
		printf("task_read_for_pid: %s\n", mach_error_string(kr));
		return 1;
	}

	struct task_dyld_info dinfo;
	mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
	if (task_info(task, TASK_DYLD_INFO, (task_info_t)&dinfo, &count) == KERN_SUCCESS && task == mach_task_self()) {
		const struct dyld_all_image_infos *all = (const void *)dinfo.all_image_info_addr;
		printf("all_image_infos: version %u, %u images, compact info %#llx size %llu, cache slide %#lx\n",
		    all->version, all->infoArrayCount, (unsigned long long)all->compact_dyld_image_info_addr,
		    (unsigned long long)all->compact_dyld_image_info_size, (unsigned long)all->sharedCacheSlide);
	}
	report_volume("/System/Library/dyld/dyld_shared_cache_arm64e");
	printf("cache by file: %s\n", dyld_shared_cache_for_file("/System/Library/dyld/dyld_shared_cache_arm64e",
	    ^(dyld_shared_cache_t c) { (void)c; }) ? "ok" : "FAILED");

	dyld_process_t process = dyld_process_create_for_task(task, &kr);
	printf("process: %s (kr %d)\n", process ? "ok" : "FAILED", kr);
	if (!process)
		return 1;
	dyld_process_snapshot_t snapshot = dyld_process_snapshot_create_for_process(process, &kr);
	printf("snapshot: %s (kr %d)\n", snapshot ? "ok" : "FAILED", kr);
	if (!snapshot)
		return 1;
	__block int images = 0;
	dyld_process_snapshot_for_each_image(snapshot, ^(dyld_image_t image) {
		(void)image;
		images++;
	});
	printf("snapshot: %d images\n", images);
	dyld_shared_cache_t cache = dyld_process_snapshot_get_shared_cache(snapshot);
	printf("shared cache: %s\n", cache ? "ok" : "FAILED");
	if (cache) {
		uuid_t uuid;
		uuid_string_t s;
		__block int files = 0, cimages = 0;
		dyld_shared_cache_copy_uuid(cache, &uuid);
		uuid_unparse(uuid, s);
		dyld_shared_cache_for_each_file(cache, ^(const char *path) {
			if (files++ == 0)
				printf("shared cache: file %s\n", path);
		});
		dyld_shared_cache_for_each_image(cache, ^(dyld_image_t image) {
			(void)image;
			cimages++;
		});
		printf("shared cache: %s base %#llx, %d files, %d images\n", s,
		    (unsigned long long)dyld_shared_cache_get_base_address(cache), files, cimages);
	} else
		failures++;

	__block int installed = 0;
	dyld_for_each_installed_shared_cache(^(dyld_shared_cache_t c) {
		(void)c;
		installed++;
	});
	printf("installed shared caches: %d\n", installed);

	dyld_process_snapshot_dispose(snapshot);
	dyld_process_dispose(process);
	printf("%s\n", failures ? "FAILED" : "PASSED");
	return failures != 0;
}
