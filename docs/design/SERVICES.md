# Services: finch-init as service manager

On macOS, launchd is PID 1, the Mach bootstrap server and the service manager. It's
closed source (and written in Swift since macOS 26). On Finch, **finch-init** does those
jobs (`userland/finch-init`). It reads launchd's job plist format, so existing
LaunchDaemons run unchanged.

## Where jobs come from

finch-init loads every `*.plist` in these directories, in this order:

| Directory | Contents |
|---|---|
| `/System/Library/Finch/LaunchDaemons` | Finch's own services (and, in the dev VM, test jobs) |
| `/Library/LaunchDaemons` | Third-party daemons, as on macOS |

Apple's `/System/Library/LaunchDaemons` is deliberately not loaded. Most of those daemons
are closed-source and expect launchd features and each other. They'll be enabled one at
a time as Finch can run them.

## Supported keys

| Key | Behaviour |
|---|---|
| `Label` | Required; unique |
| `Program`, `ProgramArguments` | What to run (`Program` defaults to `ProgramArguments[0]`) |
| `MachServices` | Names reserved at load (see below) |
| `RunAtLoad` | Start when loaded |
| `KeepAlive` | `true` restarts after any exit. `{SuccessfulExit: bool}` restarts only after a successful (or failed) exit. Other conditions are treated as `true`. |
| `ThrottleInterval` | Minimum seconds between starts (default 10, as in launchd) |
| `UserName`, `GroupName` | Run as this user and group, with supplementary groups from `getgrouplist` |
| `WorkingDirectory`, `EnvironmentVariables` | As in launchd |
| `StandardInPath`, `StandardOutPath`, `StandardErrorPath` | Default `/dev/null`. Files are opened (and created) by finch-init, so as root. |
| `Disabled` | The job isn't loaded |

Every job also gets `XPC_SERVICE_NAME=<Label>` (as launchd sets it), plus `USER`,
`LOGNAME` and `HOME` when it has a `UserName`. Jobs start in their own session with
default signal handling, and no file descriptors are inherited except 0–2.

## Mach services and launch on demand

A job's `MachServices` names exist as soon as the job is loaded. finch-init allocates
each port and holds its receive right, so clients can look the name up and send to it
before the job has ever run.

1. **Demand.** A thread waits on a port set holding every held service port. It uses a
   16-byte receive buffer with `MACH_RCV_LARGE | MACH_RCV_LARGE_IDENTITY`, so the kernel
   reports *which* port has a message without dequeuing it (launchd's technique). That
   port leaves the set, and the job starts (subject to its throttle).
2. **Check-in.** Only the job's own process may check in (the audit-token PID must
   match). Before the receive right moves to the job, finch-init registers a
   **port-destroyed notification** on it.
3. **Exit.** When the job exits, the kernel sends its receive right back to finch-init,
   with any unread messages still queued. The port rejoins the demand set, and the next
   message relaunches the job. Clients never see the port change, and their send rights
   and XPC connections keep working.

Processes may also check in names nobody declared (dynamic services). Such a name lives
until its owner's receive right dies.

## Concurrency, and why PID 1 has no bootstrap port

All registry and job state lives on one serial dispatch queue. A request thread receives
bootstrap requests and handles each one on that queue. A SIGCHLD source reaps every
child and routes the exit to the console-shell supervisor or the job manager.

finch-init sets the *task's* bootstrap port, which children inherit, but leaves its own
`bootstrap_port` global NULL. Otherwise a lookup made by PID 1 itself would deadlock: for
example, `getpwnam` for a job's `UserName` goes to Libinfo, which asks opendirectoryd
through the bootstrap server, whose handler needs the queue that is waiting. With no
bootstrap port, PID 1's own lookups use Libinfo's files module.

## Tests

- `userland/libxpc/tests/bootstrap-test.c` (host, ASan/UBSan) covers:
  - The registry rules.
  - Declared services with a fake job manager: visible before launch, demand on the first
    message, check-in only by the job, the triggering message still queued after
    check-in, the right returning with unread messages when the job's right dies, and
    clients' send rights staying valid throughout.
- `finch-xpc-service-test ondemand` (VM): a client messages `org.finch.test.ondemand`.
  finch-init launches the daemon, which answers and then exits on request. The same
  client connection then relaunches it with a new pid.
- `org.finch.test.keepalive` (VM): a job running as `nobody` with
  `KeepAlive={SuccessfulExit=false}` fails twice, is restarted, then succeeds and stays
  stopped.

## Not yet

- Per-user agents (`LaunchAgents`) and per-user domains.
- `launchctl`. There's no way to load, unload, list or kick jobs at runtime yet.
- These keys: `Sockets`, `WatchPaths`, `QueueDirectories`, `StartInterval`,
  `StartCalendarInterval`, `LaunchEvents`, `KeepAlive` conditions other than
  `SuccessfulExit`, `ExitTimeOut`, `ResetAtClose`, `HideUntilCheckIn`, `Nice`,
  `ProcessType`, resource limits.
- Shutdown: stopping jobs with SIGTERM and then SIGKILL after `ExitTimeOut`.
- Starting a fresh process takes about 2 s in the emulator, because there's no dyld
  shared cache. On-demand launch latency will fall when Finch builds one.
