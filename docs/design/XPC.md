# Finch XPC (libxpc)

**Status:** in progress (Phase 1.4). **Owner code:** `userland/libxpc/` (MIT OR Apache-2.0).

## Why

Apple's libxpc is closed, and it's load-bearing. In the macOS 26.4 ramdisk, 111 binaries
import 462 of its 800 exports. Parts of libSystem need it (libsystem_darwin and
libsystem_info won't build without `xpc/private.h`). Every Mac app reaches it through
Foundation (`NSXPCConnection`), and launchd's service model is expressed in it. Finch needs
a libxpc that is **ABI-compatible** with Apple's for the symbols that are actually used.

## Measured surface (ramdisk 25E253)

Most-imported: `xpc_get_type`, `xpc_dictionary_*`, `xpc_release`/`xpc_retain`, `xpc_array_*`,
`xpc_string_*`/`xpc_data_*`, the `_xpc_type_*` and `_xpc_error_*` objects,
`xpc_connection_*` (create_mach_service, set_event_handler, resume, send_message,
send_message_with_reply_sync, cancel), `bootstrap_look_up2`, and `xpc_pipe_*`
(Libinfo ↔ opendirectoryd). Full list: regenerate with the survey in this doc's history,
or `tools/check-exports.sh /usr/lib/system/libxpc.dylib` once ours builds.

## ABI facts (from Apple's binary)

- **XPC objects are Objective-C objects.** Each type is a class `OS_xpc_<type>` under
  `OS_xpc_object` (exported; Foundation subclasses it), which is under libdispatch's
  `OS_object`. **`_xpc_type_<type>` is that class** (same address), and
  `xpc_get_type(o)` is `object_getClass(o)`.
- **Object header** = libdispatch's `_OS_OBJECT_HEADER`: isa, `int ref_cnt`,
  `int xref_cnt`, followed by type fields. Objects are allocated with
  `_os_object_alloc_realized(cls, size)`. `xpc_retain`/`xpc_release` are
  `os_retain`/`os_release`, so ARC in client ObjC/Swift code works.
- **Singletons** (`_xpc_bool_true/false`, `_xpc_error_connection_invalid/interrupted/
  termination_imminent`, …) are statically initialised objects with a global refcount
  (`_OS_OBJECT_GLOBAL_REFCNT`), in `__AUTH_CONST` (isa signed with ptrauth).
- Error keys (`_xpc_error_key_description`, …) are `const char *` data symbols.
- Apple's libxpc depends on libdispatch (objects and `dispatch_mach` channels), libobjc,
  libsystem_*, and upward on libsystem_trace/info/notify/darwin/featureflags.

## Plan

| Step | What | Done when |
|---|---|---|
| X1 ✅ | **Object model + value types**: null, bool, int64, uint64, double, date, data, string, uuid, fd, array, dictionary, error. Create/get/set/apply, copy, equal, hash, `xpc_copy_description`. | Host unit tests pass. Exports match Apple's names for this subset. |
| X2 ✅ | **Wire format**: serialize/deserialize compatible with Apple's (`'CPX@'` message magic), so Finch processes can talk to borrowed Apple daemons and vice versa. | Round-trip tests; decodes captured Apple messages. |
| X3 ✅ | **Transport**: Mach-message connections on `dispatch_mach` channels (libdispatch `mach_private.h`), listeners, replies (sync and async), `xpc_pipe_*`, endpoints, `bootstrap_*`. | Two processes in the VM exchange messages. |
| X4 ✅ | **finch-init as bootstrap server**: owns the bootstrap port, registers Mach services from launchd-format plists (`MachServices`), launches on demand. | A test daemon is looked up and launched by name. |
| X5 ✅ | **Swap into the VM**: replace Apple's libxpc. Then unblock libsystem_darwin and libsystem_info (Finch `xpc/private.h`). | VM boots on Finch libxpc; check-exports clean for imported symbols. |

The X1 work lives in `userland/libxpc/`: C for the object types, plus one `.m` file for the
class definitions, the same way libdispatch's `object.m` does it. It's built with Finch's
own Makefile against the private-header overlay.

## Non-goals (for now)

XPC services inside app bundles (`.xpc`), `NSXPCConnection` itself (that's Foundation),
sandbox extensions, and the Apple-account-backed services.

Apple's launchd itself. finch-init is PID 1, and launchd imports private SPI nothing else
in the image uses, so Finch's libxpc doesn't export it yet, and the base image's launchd stops at "Symbol
not found" on a Finch image (`FINCH_INIT=0 tools/vm/run.sh`). As of 26.4 the missing
symbols are: the bundle SPI (`xpc_bundle_*`, `xpc_string_cache_create`,
`xpc_string_create_cached`), `_xpc_dictionary_create_reply_with_port`,
`_xpc_dictionary_extract_mach_send`, `_xpc_pipe_handle_mig`,
`xpc_pipe_create_reply_from_port`, `xpc_receive_mach_msg`,
`xpc_array_copy_mach_send`, `xpc_array_set_mach_send`, `xpc_date_get_value_absolute`,
`xpc_dictionary_apply_f` and `xpc_exit_reason_get_label`.

## Progress log

- **X1 (2026-10-06):** `userland/libxpc` builds as an arm64e `libxpc.dylib`. 39/39 host
  unit tests pass (`make -C userland/libxpc test`). Covers 100 of the 462 libxpc symbols
  the ramdisk imports. Still missing, by area: ~216 `xpc_*` (connections, pipes,
  activities, endpoints), 57 `launch_*` and 30 `vproc_*` (liblaunch, now part of
  libxpc), and 20 `bootstrap_*`.
  - Host tests run next to the system libxpc, so the ObjC runtime warns that the
    `OS_xpc_*` classes are implemented twice. That's expected: every call in the test
    binds to Finch's library.
- **X2 (2026-10-06):** Wire format for every inline value type (`serialize.c`), with
  `xpc_make_serialization` / `xpc_create_from_serialization` at Apple's ABI. Ground truth
  comes from `tools/xpc-capture`, which records Apple's own serializations on a real Mac
  (`userland/libxpc/tests/fixtures/apple-25E253.txt`). Finch decodes all 16 samples and
  re-encodes them byte for byte. The exception is multi-key dictionaries: Apple writes
  them in hash order, so those are compared by meaning, not bytes. The decoder is fuzzed
  (every truncation plus 5,000 random corruptions per sample) and is clean under
  `make asan`. Port-carrying types (fd, Mach rights, endpoints, shmem) come with X3.
- **X3a (2026-10-06):** Mach transport for messages (`message.c`), port-carrying
  values (fd as fileport, Mach send rights, endpoints), and `xpc_pipe`
  (`pipe.c`: create_from_port, simpleroutine, routine, receive, routine_reply), plus
  `xpc_dictionary_create_reply`. `tests/interop-test.c` runs Finch's and Apple's libxpc
  in one process and exchanges real Mach messages both ways, with fds crossing in each
  direction (9/9, also under ASan). Gotcha: Apple's `xpc_pipe_receive` returns `EAGAIN`
  when its wait is interrupted, and callers retry.
  Next: X3b, connections (w00t handshake, listeners, peers, async/sync replies).
- **X3b (2026-10-06):** Connections (`connection.c`): anonymous and Mach-service
  listeners, peers, clients from endpoints and service names, the w00t handshake, one-way
  messages, async and sync replies (send-once reply rights, with dropped requests becoming
  errors instead of hangs), server-to-client messages, death detection (client:
  dead-name on S, giving interrupted+reconnect for named services and invalid for
  endpoints; peer: no-senders on S, giving invalid), audit-token getters, contexts and
  finalizers. `tests/conn-test.c`: Finch↔Finch (incl. 200 concurrent requests and fds
  over a connection), an **Apple client → Finch listener**, and a **Finch client →
  Apple listener**. 9/9, clean under ASan/UBSan. `bootstrap_*` are placeholders until X4.
  Coverage: 144/462 imported symbols. Top missing: `bootstrap_look_up2`,
  `os_transaction_create`, `xpc_connection_activate`, `xpc_create_from_plist`.
- **X5 (2026-10-06): the VM runs on Finch's libxpc.** On macOS 26, libobjc links
  libswiftCore, which brings Foundation, CoreFoundation and about 170 other libraries
  into every process. The real requirement is therefore the *transitive* import closure:
  290 libxpc symbols, not the 119 that libSystem's own libraries import. `plist.c`
  (`xpc_create_from_plist`, 341/341 files identical to Apple's, fuzzed), `runtime.c`
  (libSystem initializer and atfork hooks, csops entitlements, bundles, pipe-by-name) and
  `compat.c` (sessions and listeners over connections, rich errors, entitlement-based
  peer requirements, transactions, shmem, pointers, send-once rights, reply helpers,
  `_availability_version_check`) now cover all 290. The deliberate gaps are marked
  `FINCH-NOT-YET` and fail safe: activities never fire, event streams are silent,
  launchd job routines return `ENOTSUP`, and code-signing requirements never match.
  Boot result: finch-init (PID 1), rc and zsh run with `/usr/lib/system/libxpc.dylib`
  checksum-identical to the build. The one boot bug: libnotify calls
  `xpc_copy_entitlement_for_token(key, NULL)`, where NULL means "self".
  Next: X4, finch-init as bootstrap server, after which `bootstrap_look_up` becomes real
  (user lookups via opendirectoryd depend on it).
- **X4 (2026-10-06): finch-init is the bootstrap server.** `userland/finch-init/bootstrapd.c`
  (a registry thread in PID 1) answers launchd's check_in and look_up routines
  (XPC-protocol.md, "Bootstrap"), and Finch libxpc's `bootstrap_*` now speak that protocol.
  The rules: check-in creates a service and moves the receive right to the caller; a live
  name can't be taken over; a name is released when its owner dies. Host tests:
  `tests/bootstrap-test.c` (24/24, clean under ASan/UBSan) runs the real server against the
  real client, including XPC connections and sessions resolved through it. VM:
  `finch-xpc-service-test` spawns a listener process and talks to it with a connection and
  a session, then checks that the name is released when the listener exits. All of that
  passes on Finch. Bug found on the way: libxpc must initialise `bootstrap_port` itself
  (at startup and after fork). Apple's libxpc had been masking this in the host tests.
  FINCH-NOT-YET: declared services (MachServices from launchd plists, which reserve a
  name and launch the job on demand), ownership policy, per-user domains.
  Next: libsystem_darwin and libsystem_info on Finch libxpc, then service supervision in
  finch-init.
- **libsystem_info and libsystem_darwin (2026-10-06): built by Finch, on Finch libxpc.**
  Finch's `xpc/private.h` (`userland/sdk/include`) declares the libxpc SPI these
  components compile against. Other unpublished headers are reconstructed from first-hand
  sources:
  - `opendirectory/odipc.h`: OD service names and RPC keys, taken from `launchctl` and the
    strings in macOS 26.4's libsystem_info.
  - `bootstrap_priv.h`: flags from launchd-842.
  - `dns_sd_private.h`: one symbol that libsystem_dnssd exports.
  - `dnsinfo.h`: copied from configd-1405.100.8, now pinned.
  - `os/transaction_private.h`.

  Libinfo builds without the closed Darwin Directory module. libdarwin's dead APFS
  fast path is compiled out (`userland/patches/Libc/0002`). Exports match Apple's: 431/431
  for libsystem_info and 75/75 for libsystem_darwin. In the VM, `id` and `whoami`
  resolve through Finch's libsystem_info using /etc files.
  Measured: a fresh process takes about 2 s to start in the emulator, because there's
  no dyld shared cache and each process maps about 170 dylibs one by one. A Finch shared
  cache is worth doing before services start launching on demand.
