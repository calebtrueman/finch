# Hardened processes on Finch

Apple daemons increasingly carry `com.apple.developer.hardened-process` (or
`com.apple.security.hardened-process`). At exec, XNU turns that entitlement into a set of
mitigations: guard objects, IPC containment, platform restrictions, and the
hardened heap with `.hardened-heap` (`bsd/kern/kern_exec.c`,
`exec_security_mitigation_entitlement`). Finch supports them: binaries keep the
entitlements their projects declare (`tools/build-oss.sh`), and
`finch-hardened-test` (`userland/tests`) runs in the VM signed with them.

## The libplatform `__TPRO_CONST` bug (fixed 2026-10-07)

**Symptom.** Once `build-oss.sh` kept declared entitlements, Finch's notifyd died at
start with SIGBUS, in a respawn loop. Bisected in the VM, `hardened-process` was the
cause; a trivial program with it died the same way, before `main`.

**Fault.** `finch-excwatch` (`userland/devtools`, allowed to handle a hardened
process's exceptions) reported `EXC_BAD_ACCESS` / `KERN_PROTECTION_FAILURE`. The pc,
resolved against the shared cache map, was in libsystem_platform's
`__os_security_config_init`, writing its own `__TPRO_CONST` section. Without the dyld
shared cache, the same program ran.

**Cause.** The published libplatform source tags `__security_config` with
`section("__TPRO_CONST,__data")`. Apple's shipped libsystem_platform has no
`__TPRO_CONST` segment: the variable is in `__DATA_DIRTY`. Finch rebuilds libplatform
from a reconstructed recipe, which kept the source's section. The dyld shared cache
maps `__TPRO_CONST` as TPRO memory for hardened processes, so libSystem's
initializer wrote to a read-only page.

**Fix.** `userland/oss/libplatform.build.sh` links with
`-rename_section,__TPRO_CONST,__data,__DATA_DIRTY,__data`, as Apple ships it.

**Tools this left behind.** `finch-excwatch` reports a process's first exception,
registers and shared-cache slide in the VM. `finch-hardened-test` steps through
malloc, dispatch, os_log and XPC as a hardened process.
