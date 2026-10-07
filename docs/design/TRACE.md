# libsystem_trace: Finch's os_log

`/usr/lib/system/libsystem_trace.dylib` is the last big closed library on the Phase 1
boot path (`PHASE1-EXIT.md`). It implements os_log, os_signpost, os_activity, os_state
and os_trace for every process. 197 exports, 83 imported by something in the image;
the hot ones (`os_log_type_enabled`, `_os_log_impl`, `_os_log_default`,
`os_log_create`, `_os_log_error_impl`) are imported by 100+ images each.

## What Apple's does, and what Finch's does in Phase 1

On macOS a log call encodes its arguments into a compact buffer
(`__builtin_os_log_format`, whose layout is public in clang), writes it into a
per-process firehose buffer shared with the kernel, and logd drains the buffers into
the log store, where `log show` decodes them later.

The Finch image runs no logd, so with Apple's library today every message is dropped
unless `OS_ACTIVITY_DT_MODE` is set, which also echoes it to stderr. Finch's Phase 1
library does the same, so nothing changes for programs:

- The ABI is Apple's: the same exports, data symbols (`_os_log_default`,
  `_os_log_disabled`, `OS_os_log` class, ...), object layouts callers touch, and SPI
  shapes (`_os_log_send_and_compose_impl`, `os_log_pack_*`, `os_log_set_hook`, ...).
- Messages are encoded and composed exactly as Apple's: the same text for every
  format, including the value formatters documented in `os_log(5)`
  (`%{errno}d`, `%{bool}d`, `%{time_t}d`, `%{uuid_t}.16P`, `%{bitrate}d`, data with
  `%.*P`, ...) and privacy redaction (`<private>`).
- Delivery: hooks registered with `os_log_set_hook` see every message; stderr gets it
  in DT mode; nothing is stored. A Finch log daemon and store (and a `log` tool) are
  later work, after Phase 1.
- Levels: which types are enabled per subsystem and category follows Apple's
  defaults (default, error and fault on; info and debug off unless configured).
- Signposts, activities and os_state: identifiers, scopes and handler registration
  behave as Apple's; with no store there is nothing to record them in.

## Stages

1. **T1 Composition.** The buffer decoder and formatter: `_os_log_send_and_compose_impl`
   with `OS_LOG_F_COMPOSE`, `os_log_copy_decorated_message`, `os_log_pack_compose`.
   Differential test: a generated corpus of formats and arguments composed by both
   libraries.
2. **T2 Logging ABI.** `os_log_t` objects (`os_log_create`, the static logs, the ObjC
   class), `os_log_type_enabled` and levels, the `_os_log_*_impl` entry points, packs,
   hooks, `os_trace_set_mode`, DT mode.
3. **T3 Signposts, activities, state, metrics.** Identifiers and enablement.
4. **T4 The rest.** The `_os_trace_*` utility exports other system libraries call (file
   and memory helpers, preference paths, boot UUID), `RTLog*` ring buffers, then
   generated stubs for whatever nothing calls. Build, `check-exports.sh`, VM.

## Status (2026-10-07)

Finch's library is in the image: `tools/build-system.sh` runs `make -C
userland/libsystem/trace install`. It is linked as Apple's is: 197/197 exports
(`tools/check-exports.sh` agrees), the same version and umbrella, and the same
20 dependencies in the same order (libobjc and corecrypto upward, asl upward
and delay-init). It boots under finch-init, and `finch-log-test`
(`userland/tests`) passes in the VM. That test logs in DT mode and checks what
arrives: composition, `%{errno}d` and `%{bool}d`, level gates, signposts and
activities. `make check` passes. It
compares against the host library across composition, the format SPI, stream
entries, log objects, levels and modes, activities and signposts, metrics,
images, blobs, RTLog rings, preferences and diagnostic streams, and it covers the
transport, control, storage, AMFI and RT-connection paths with mock peers.

Faults: `finch_log_send` opens a fault scope. It sends a crash report when the
log's `Enable-Fault-Crashlogs` setting asks for one, and asks registered state
handlers for a dump under their own activity. After the caller's voucher is
restored, it calls the fault callback, then the test callback. Error and fault
counters decide "first". TTLs come from the log's preferences. The state sender
marks packets while the process is quarantined, and libdispatch's quarantine
hook is wired to `finch_trace_quarantine`. `fault-test` covers the logic with
mocks, and `fault-callbacks` covers the callbacks through the built library.

Two boot lessons, both matching what Apple's library does:

- Preference changes are watched (a notify registration) only once the
  process is multithreaded, and the registration runs on the watcher's queue.
  Registering on first use deadlocked notifyd: it logs during single-threaded
  startup, so its registration request waited on itself, and every notify
  client (zsh, through Libinfo) then hung.
- The `logd` port hook skips the bootstrap lookup while tracing is disabled for
  the process or, through the commpage word, system-wide.
