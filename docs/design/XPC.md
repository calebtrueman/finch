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
| X2 | **Wire format**: serialize/deserialize compatible with Apple's (`'CPX@'` message magic), so Finch processes can talk to borrowed Apple daemons and vice versa. | Round-trip tests; decodes captured Apple messages. |
| X3 | **Transport**: Mach-message connections on `dispatch_mach` channels (libdispatch `mach_private.h`), listeners, replies (sync and async), `xpc_pipe_*`, endpoints, `bootstrap_*`. | Two processes in the VM exchange messages. |
| X4 | **finch-init as bootstrap server**: owns the bootstrap port, registers Mach services from launchd-format plists (`MachServices`), launches on demand. | A test daemon is looked up and launched by name. |
| X5 | **Swap into the VM**: replace Apple's libxpc. Then unblock libsystem_darwin and libsystem_info (Finch `xpc/private.h`). | VM boots on Finch libxpc; check-exports clean for imported symbols. |

The X1 work lives in `userland/libxpc/`: C for the object types, plus one `.m` file for the
class definitions, the same way libdispatch's `object.m` does it. It's built with Finch's
own Makefile against the private-header overlay.

## Non-goals (for now)

XPC services inside app bundles (`.xpc`), `NSXPCConnection` itself (that's Foundation),
sandbox extensions, and the Apple-account-backed services.

## Progress log

- **X1 (2026-10-06):** `userland/libxpc` builds as an arm64e `libxpc.dylib`. 39/39 host
  unit tests pass (`make -C userland/libxpc test`). Covers 100 of the 462 libxpc symbols
  the ramdisk imports. Still missing, by area: ~216 `xpc_*` (connections, pipes,
  activities, endpoints), 57 `launch_*` and 30 `vproc_*` (liblaunch, now part of
  libxpc), and 20 `bootstrap_*`.
  - Host tests run next to the system libxpc, so the ObjC runtime warns that the
    `OS_xpc_*` classes are implemented twice. That's expected: every call in the test
    binds to Finch's library.
