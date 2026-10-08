# POSIX conformance

Status: planned (ROADMAP Phase 3, after the GUI stack, alongside the bare-metal
userland). Lower priority than macOS compatibility.

## Why
- **Software portability.** The existing Unix ecosystem builds and runs without
  patches: autotools projects, scripts that assume POSIX `sh`, `make`, `awk` and
  `sed` behavior, and build systems like Homebrew's. This matters most on bare metal
  with no donor macOS, where Finch builds its own toolchain and packages.
- **A fixed target for correctness.** POSIX defines exactly how `fork`, signals,
  `pthread`, file locking, `errno` values and `termios` behave. Conformance tests catch
  bugs in Finch's own code (finch-init, the launchd replacements, Libc patches) that
  ad-hoc tests miss. It's the diff-against-Apple method, against a published spec.
- **Developer trust.** "POSIX-conformant" tells people Finch is a real Unix.
- **A reference that outlives Apple.** macOS keeps moving; POSIX doesn't. It's a
  stable baseline for the parts of the system Finch owns.

## How it fits the main goal
macOS is certified UNIX 03, so matching Apple and matching POSIX usually agree. Where
they differ, Apple's Libc chooses through `$UNIX2003` symbol variants and
`COMMAND_MODE`, and Finch keeps Apple's defaults.

## Limits
- It does little for app compatibility: Cocoa apps rarely touch POSIX corners.
- No formal certification: it's expensive and mostly useful for procurement.
- It takes time from Phase 2 (CoreGraphics, the window server, AppKit), so it waits
  until after the GUI stack.

## Plan
- Run an open conformance suite (the Open POSIX Test Suite for interfaces; shell and
  utility checks for `sh`, `make`, `awk`, `sed`) in the VM, then on metal.
- Triage each failure: Finch bug (fix), Apple-sanctioned divergence (record and keep),
  or test-suite issue.
- Build a set of unpatched autotools and Homebrew-style projects as a portability check.
