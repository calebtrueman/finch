# Logging preferences checks

`preferences.c` implements the exported preference readers, option builder,
merge rules, cache copy, mode checks, boot argument reader, and diagnostic flag
calls. It also watches the preference change notification and refreshes a log
object from its subsystem and category settings.

The host comparison passed 267,034 checks. These cover option bytes, typed
fallbacks, nested merges, special signpost categories, commpage flags, XML and
binary files, bad files, size limits, and the current read-only host settings.
The tests create and remove their own temporary files. Each replacement symbol
is checked with `dladdr` so a missing export cannot quietly use the host code.

The separate wire test replaces calls that could change machine settings. It
checks boot argument parsing, Mach port cleanup, launchd's eight platform flag
combinations, preference change counts, cache version checks and cleanup, and
the order of system, cryptex, bundle, and local settings. No test writes real
system preferences or calls the real diagnostic flag setter.

Build the host check with `preferences.c` and `util.c`, using arm64e, blocks,
and the normal trace build flags. Build `tests/preferences-compare.c` as a
separate program and pass it the resulting library path.

For the wire test, compile only `preferences.c` with these call replacements,
then link that object with `tests/preferences-wire.c`:

```
sysctlbyname=test_preferences_sysctl
mach_host_self=test_preferences_host_self
host_set_atm_diagnostic_flag=test_preferences_set_flags
mach_port_deallocate=test_preferences_port_free
notify_register_dispatch=test_preferences_notify
voucher_get_activity_id=test_preferences_activity
voucher_activity_get_logging_preferences=test_preferences_cache
mach_vm_deallocate=test_preferences_vm_free
xpc_bundle_create_main=test_preferences_bundle
xpc_bundle_get_info_dictionary=test_preferences_bundle_info
_os_trace_read_file_at=test_preferences_read
os_variant_check=test_preferences_variant
os_variant_is_recovery=test_preferences_recovery
os_variant_has_internal_diagnostics=test_preferences_internal
```

The cache copy call reads the real dispatch preference mapping, accepts version
6, returns a malloc copy, and releases the Mach mapping. The refresh helper
selects subsystem and category records from that copy. Missing categories use
the subsystem settings; missing subsystems use the standard defaults. The two
special tracing categories receive the same default changes as the host.
Bundle entries take priority and use the file-and-bundle path. Each record is
bounds checked before reading its name, settings, or children. Malformed sibling
lists stop at the first bad record. Runtime-owned option bits are preserved.

The wire test adds 9,312 comparisons with the host record reader, plus populated
cache selection, category fallback, special category defaults, bundle priority,
notification generation, and saved-error checks. The private host reader is
reached using its measured offset from the exported compute call in the inspected
macOS 26 image. This test offset must be rechecked on another host build. The
replacement reader is linked directly into this test, so it cannot fall back to
a host symbol. The live host cache was empty; populated records were supplied by
the test in the same layout, without writing daemon settings.

These files do not own log transport, per-process mode loading, or stream
filter refresh. Those are wired by the trace runtime.
