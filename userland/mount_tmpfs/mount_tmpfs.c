/*
 * Copyright (c) 2026 The Finch Project contributors.
 * SPDX-License-Identifier: MIT OR Apache-2.0
 *
 * mount_tmpfs: mount macOS's tmpfs file system.
 *
 *   mount_tmpfs [-o options] [-i | -e] [-n max_nodes] [-s max_mem_size] <directory>
 *
 * Apple doesn't publish this tool. Its interface was read from macOS 26.4's
 * binary: standard mount options, -i/-e (mutually exclusive; -e clears the
 * last argument word), a node limit (default 1,000,000), and a size with an
 * optional k/m/g/t suffix, rounded up to whole pages and capped at half of
 * physical memory (about twelve thirteenths when the system allows Apple-
 * internal configurations). If the kernel doesn't know tmpfs yet, the kext is loaded first.
 */

#include <sys/types.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <err.h>
#include <errno.h>
#include <mach/vm_page_size.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <mntopts.h>

/* <sys/csr.h> (private) */
#define CSR_ALLOW_APPLE_INTERNAL (1 << 4)
int csr_check(uint32_t mask);

#define TMPFS_NAME "tmpfs"
#define TMPFS_KEXT "/System/Library/Extensions/tmpfs.kext"
#define KEXTLOAD "/sbin/kextload"
#define DEFAULT_MAX_NODES 1000000
#define EX_USAGE 64

/* The third argument to mount(2), as the kernel's tmpfs reads it. */
struct tmpfs_mount_args {
	uint64_t max_pages;
	uint64_t max_nodes;
	uint64_t case_insensitive;   /* 1 unless -e */
};

static const struct mntopt mopts[] = {
	MOPT_STDOPTS,
	MOPT_UPDATE,
	{ NULL, 0, 0, 0 },
};

extern int getmnt_silent;

static int
usage(int status)
{
	puts("usage: mount_tmpfs [-o options] [-i | -e] [-n max_nodes] [-s max_mem_size] <directory>");
	return status;
}

static int
invalid(int option, const char *value)
{
	fprintf(stderr, "invalid value for '-%c': %s\n", option, value);
	return EX_USAGE;
}

/* Load the tmpfs kext if the kernel doesn't know the file system yet. */
static int
load_tmpfs(void)
{
	struct vfsconf vfc;
	int status = 0;
	pid_t pid;

	if (getvfsbyname(TMPFS_NAME, &vfc) == 0) {
		return 0;
	}
	pid = fork();
	if (pid == 0) {
		execl(KEXTLOAD, KEXTLOAD, TMPFS_KEXT, (char *)NULL);
		_exit(errno);
	}
	if (pid == -1 || wait4(pid, &status, 0, NULL) != pid || (status & 0x7f) != 0) {
		if (errno != 0) {
			fprintf(stderr, "could not load kernel extension, return code %d\n", errno);
			return errno;
		}
	} else if (WEXITSTATUS(status) != 0) {
		fprintf(stderr, "could not load kernel extension, return code %d\n", WEXITSTATUS(status));
		return WEXITSTATUS(status);
	}
	if (getvfsbyname(TMPFS_NAME, &vfc) != 0) {
		err(1, "tmpfs kext not loaded (searched for %s file system)", TMPFS_NAME);
	}
	return 0;
}

int
main(int argc, char *argv[])
{
	struct tmpfs_mount_args args;
	uint64_t memsize = 0, limit, size;
	size_t len = sizeof(memsize);
	long long max_nodes = 0, requested = 0;
	bool insensitive = false, exact = false;
	int mntflags = 0, ch, rc;

	while ((ch = getopt(argc, argv, "io:en:s:h")) != -1) {
		switch (ch) {
		case 'o': {
			int altflags = 0, flags = 0;
			mntoptparse_t mp;

			getmnt_silent = 0;
			mp = getmntopts(optarg, mopts, &flags, &altflags);
			if (mp == NULL) {
				err(1, "error parsing mount options");
			}
			mntflags = flags;
			freemntopts(mp);
			break;
		}
		case 'i':
			insensitive = true;
			break;
		case 'e':
			exact = true;
			break;
		case 'n':
			max_nodes = strtoll(optarg, NULL, 10);
			if (max_nodes <= 0) {
				return invalid('n', optarg);
			}
			break;
		case 's': {
			char *end = NULL;

			requested = strtoll(optarg, &end, 10);
			switch (*end) {
			case 'k': case 'K': requested <<= 10; end++; break;
			case 'm': case 'M': requested <<= 20; end++; break;
			case 'g': case 'G': requested <<= 30; end++; break;
			case 't': case 'T': requested <<= 40; end++; break;
			}
			if (end == optarg || *end != '\0' || requested <= 0) {
				return invalid('s', optarg);
			}
			break;
		}
		case 'h':
			return usage(0);
		default:
			return usage(EX_USAGE);
		}
	}
	if (optind != argc - 1 || (insensitive && exact)) {
		return usage(EX_USAGE);
	}

	rc = load_tmpfs();
	if (rc != 0) {
		return rc;
	}

	/* Size limit: half of memory, or 12/13 of it where Apple-internal is allowed. */
	if (sysctlbyname("hw.memsize", &memsize, &len, NULL, 0) != 0) {
		limit = (uint64_t)vm_kernel_page_size * DEFAULT_MAX_NODES;
		fprintf(stderr, "Could not get the hw memory size, errno = %d (%s)\n", errno, strerror(errno));
	} else if (csr_check(CSR_ALLOW_APPLE_INTERNAL) == 0) {
		limit = memsize / 13 * 12;
	} else {
		limit = memsize / 2;
	}
	size = limit;
	if (requested > 0) {
		uint64_t rounded = ((uint64_t)requested + vm_kernel_page_size - 1) / vm_kernel_page_size *
		    vm_kernel_page_size;
		if (rounded > limit) {
			fprintf(stderr, "Desired memsize %lld too large - defaulting to %lld bytes\n",
			    (long long)rounded, (long long)limit);
		} else {
			size = rounded;
		}
	}

	args.max_pages = size / vm_kernel_page_size;
	args.max_nodes = max_nodes ? (uint64_t)max_nodes : DEFAULT_MAX_NODES;
	args.case_insensitive = !exact;
	if (mount(TMPFS_NAME, argv[optind], mntflags, &args) != 0) {
		err(1, "Unsuccessful mount");
	}
	return 0;
}
