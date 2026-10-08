# finch-logd and log(1)

Finch's log daemon receives every process's os_log messages and stores them for
`log show` and `log stream`. Status: working in the VM (see the end).

## Transport

Finch's libsystem_trace (`docs/design/TRACE.md`) writes each message into the
process's firehose buffer in Apple's tracepoint format, through libdispatch, as
Apple's library does. libdispatch's firehose client looks up `com.apple.logd`
through the trace hooks. It registers with logd on its first push, and logd sees a
chunk when the chunk is pushed or when the process exits. Finch's library pushes a
process's first message, which registers it, and every error and fault
(`transport.c`, `finch_trace_send`).

finch-init (PID 1) turns its own tracing off: it serves the bootstrap namespace, so
it can't look logd up through itself.

## The daemon (`userland/logd/logd.c`)

- It is the `com.apple.logd` job (`userland/LaunchDaemons/com.apple.logd.plist`,
  KeepAlive), and checks in the service with `bootstrap_check_in`.
- It uses libdispatch's open-source firehose server (`libfirehose_server.a`, the
  `libfirehose_server` target of libdispatch, built for arm64e through
  `userland/oss/libdispatch.xcconfig`). Its tracepoint reader macros come from the
  same project.
- It decodes log tracepoints (namespace 4) the way `transport.c` encodes them:
  - the location prefix: shared cache (4- or 6-byte offset), main executable,
    another image by UUID, or absolute;
  - the high bits of the format offset (flag 0x20);
  - the subsystem id (flag 0x200), looked up in the client's metadata page;
  - oversize messages (flag 0x800), stored as a placeholder for now.
- It finds format strings in its own mapping of the shared cache when the client
  uses the same cache. Otherwise it reads them from the client's binaries on disk:
  the main executable's path is in the metadata page, and other images' paths come
  from the loader-namespace records (namespace 5).
- It composes messages with libsystem_trace's `os_log_fmt_compose`, with private
  values redacted, so the text is exactly what the process would compose.
- It appends records (`logstore.h`) to `/var/log/finch/os_log.records`, rotating
  to `.0` at 16 MiB. `/var/db/diagnostics` isn't writable in the dev image.

## log(1) (`userland/logd/log.c`)

- `log show` and `log stream`, filtered by `--last`, `--process`, `--subsystem`,
  `--category` and `--type`, with `--info`, `--debug` and
  `--style default|compact|syslog`.
- `--predicate` isn't supported yet.

## Not yet

- Live streaming: Apple's clients send each message directly while a `log stream`
  is attached (`com.apple.logd.realtime`). Finch's `log stream` sees messages only
  when their chunk is pushed.
- `com.apple.logd.events`: oversize messages.
- Kernel messages: the kernel's firehose client (pid 0) is skipped; its format
  strings are in the kernel collection, which logd doesn't read yet.
- Signposts and activities, and Apple's binary tracev3 store format.

## Status

Working in the VM (2026-10-08): `finch-log-test`'s messages are stored and
`log show --process finch-log-test` prints them with subsystem, category and the
`%{errno}d` and `%{bool}d` formatters composed. Timestamps read 1970 because the
emulated machine has no wall clock set.
