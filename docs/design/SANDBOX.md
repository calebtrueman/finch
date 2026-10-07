# Finch's sandbox library

The library sends checks and access requests to the kernel's Sandbox policy.
It does not replace that policy. Profile compilation still uses
`/usr/lib/libsandbox.1.dylib` when that compiler is available.

The exported names, request numbers and field positions were checked against
Sandbox-2680.100.174 from the local macOS 26.4.1 test disk. The build exports the
same 166 names with the same install name, version and System umbrella.
No Apple library code is included in Finch's sources.

## File trust

`rootless_check_trusted`, its file-handle form and its storage-class form first
check SIP and the sealed root volume. For other files, they send a
`file-write-data` check for PID 1 to Sandbox. The request is 160 bytes long;
the storage-class pointer sits at byte 56. A failed kernel call returns -1.
The trust answer is zero only when the kernel's result is exactly 1.

The root-volume check reads mount flags and volume capabilities, then the
extended file flags. A synthetic directory does not inherit the sealed
volume's trust. Like Apple's library, a sealed root volume without the
extended-flags query uses the older volume-only answer.

Protected-volume queries use calls 259 and 260. Directory creation uses
call 261 before setting the file flags. It opens the parent first, avoids
following links to the child, and checks the child's device, file number
and flags again after protection. On failure it removes only a directory
created by that call and keeps the original error.

Removing a storage class asks the kernel for permission with call 263,
clears the relevant flags from children before their parent, and finishes
with call 262. The walk stays on one filesystem and does not follow links.

`_amkrtemp` reads and caches the kernel's sandbox sentinel, then returns a
candidate name. It does not create the file; callers retain that job.

## Deliberately unsupported

These nine exports have no caller in the stock boot image and return an
unsupported error rather than claiming to protect a file:

- `rootless_apply`, `rootless_apply_relative`, `rootless_apply_internal`
- `rootless_manifest_parse`, `rootless_manifest_free`, `rootless_preflight`
- `rootless_convert_to_datavault`
- `gpu_bundle_find_trusted`, `gpu_bundle_is_path_trusted`

Pointer results are null, integer results are -1, and preflight returns false.
The manifest free function accepts null; a non-null argument sets ENOTSUP.
The earlier sandbox client also retains its stated unsupported cases.

## Checks

Run `make -C userland/libsystem/sandbox check`.

The host comparison currently checks 389 results: constants, buffer layout,
length limits, sandbox queries, trust checks, bad paths and file handles,
temporary names, and protected-directory failures and cleanup. Directory
checks use a fresh test folder and remove it afterward. They do not alter
the host's sandbox or SIP settings.

The separate request test checks 1,060 conditions with supplied kernel
answers. It covers SIP on and off, sealed and synthetic paths, failed
attribute reads, trust answers other than 0 and 1, and failed kernel calls.
This covers branches that one host's SIP settings cannot exercise.

The rebuilt Finch image also reached its shell in QEMU with this library and
the added dispatch queue-thread function. `finch-images` listed the loaded
libraries, and Foundation's `plutil` checked the notifyd property list.
This does not test successful protection changes by an entitled process.
