# Hardened processes on Finch: open issue

Apple daemons increasingly carry `com.apple.developer.hardened-process` (or
`com.apple.security.hardened-process`). At exec, XNU turns that entitlement into a set of
mitigations: guard objects, IPC containment, platform restrictions, and the
hardened heap when `.hardened-heap` is also present (`bsd/kern/kern_exec.c`,
`exec_security_mitigation_entitlement`).

**Symptom (2026-10-07):** once `tools/build-oss.sh` started keeping each target's
declared entitlements, Finch's notifyd (Libnotify-348.100.7) gained
`hardened-process`, `hardened-process.hardened-heap`,
`com.apple.private.xpc.launchd.ios-system-session` and `seatbelt-profiles`. It then
died at once with SIGBUS, in a respawn loop. Bisected in the VM:

| notifyd's entitlements | Result |
|---|---|
| all four | SIGBUS |
| without `.hardened-heap` | SIGBUS |
| none | runs |
| without `hardened-process` (and its heap variant) | **runs** |

So the hardened-process mitigations are the cause. Apple's notifyd runs with them on
Apple's libraries, so on Finch one of the Finch-built or Finch-written libraries under
notifyd trips a mitigation. Finch's libxpc Mach-port handling is the first suspect
(guard objects); the hardened heap in Finch's libmalloc build is the second. The VM
gives no crash report yet: AMFI denies the core dump.

**For now:** `build-oss.sh` signs every product with its declared entitlements except
the `*.hardened-process*` family. Anything else (`ps`'s task-port read entitlement,
notifyd's seatbelt profile) is kept.

**Next:** get the faulting address and thread state, for example by letting finch-init
report the exit's `si_addr`, or by catching the exception under the VM debugger
(`docs/DEV_VM.md`). Then fix the library that trips the mitigation and drop the filter.
