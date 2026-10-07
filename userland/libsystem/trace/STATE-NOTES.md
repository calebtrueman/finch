# State checks and transport hooks

`tests/state-compare.c` compares 256 handler registrations with the host. Both
sides return increasing tokens and accept repeated removals and unknown tokens.
The test releases its queue while handlers still hold it, then removes them.

`tests/state-wire.c` checks queued callbacks, copied hints, a second request
while one is running, removal and registration during a callback, batches of
ten entries, null results, oversized results, and the outgoing Mach request.
It replaces only the send-related calls in the test's copy of `state.c`.
It does not ask other processes to provide their state.

The wire test builds `state.c` with these name replacements:

```
-Ddebug_control_port_for_pid=test_debug_control_port_for_pid
-Dmach_msg=test_state_mach_msg
-Dmach_port_deallocate=test_state_port_deallocate
-Dvoucher_get_activity_id=test_state_activity_id
-D_os_activity_initiate=test_state_activity
```

Compile that object and `tests/state-wire.c` with `-fblocks`. The ordinary
library uses the real Mach calls, with a 50 ms send timeout and port cleanup.

The incoming hook is
`finch_trace_state_request(activity_id, hints, ttl, image_header)`. Hints have
24 bytes: version (32 bits), reserved (32 bits), data (64 bits), type (32 bits),
and flags (32 bits). A system request uses `{1, 0, 0, 3, 1}`, TTL 14, and no
image filter. A fault uses type 1 and its image header. The caller's hints are
copied before the function returns.

A handler returns a malloc-owned block with two 32-bit fields (type and payload
size), three 64-byte names, and the payload. The code frees the block after
copying it into XPC. Payloads of 32,569 bytes or more are skipped. Name endings
are cleared. Successful results are grouped into operation 2 dictionaries,
with activity ID, shared-cache UUID, and up to ten entries. Each entry contains
the data, timestamp, image UUID, and optional TTL. `finch_trace_state_send`
forwards that dictionary to logd.

The host comparison and local wire test pass. Receipt by logd, remote process
permissions, and incoming debug-port setup belong to the main transport tests.
Quarantine handling is not implemented in this file; its sender must apply
the process's current quarantine state.
