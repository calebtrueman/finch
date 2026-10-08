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

Per-user agents come from other directories when a user's domain is created (see
"Domains" below).

Finch's job plists live in `userland/LaunchDaemons` and are installed into
`/System/Library/Finch/LaunchDaemons`. They keep Apple's labels and service names
(for example `com.apple.notifyd` serving `com.apple.system.notification_center`), so
clients find them by the usual names.

| Job | Program | Started |
|---|---|---|
| `com.apple.notifyd` | notifyd (Libnotify, built from source) | On demand, by the first notify client |
| `com.apple.syslogd` | syslogd (syslog, built from source) | At boot; kept alive |

## Supported keys

| Key | Behaviour |
|---|---|
| `Label` | Required; unique |
| `Program`, `ProgramArguments` | What to run (`Program` defaults to `ProgramArguments[0]`) |
| `MachServices` | Names reserved at load (see below) |
| `RunAtLoad` | Start when loaded |
| `KeepAlive` | `true` restarts after any exit. `{SuccessfulExit: bool}` restarts only after a successful (or failed) exit. Other conditions are treated as `true`. |
| `ThrottleInterval` | Minimum seconds between starts (default 10, as in launchd) |
| `UserName`, `GroupName` | Run as this user and group, with supplementary groups from `getgrouplist`. Ignored for agents, which run as their domain's user. |
| `LimitLoadToSessionType` | Agents only: see "Domains" |
| `WorkingDirectory`, `EnvironmentVariables` | As in launchd |
| `StandardInPath`, `StandardOutPath`, `StandardErrorPath` | Default `/dev/null`. Files are opened (and created) by finch-init, so as root. |
| `Disabled` | The job isn't loaded |
| `StartInterval` | Start every N seconds |
| `StartCalendarInterval` | Start when the local time matches a dictionary (or one of an array of them) of `Minute`, `Hour`, `Day`, `Weekday` (0 or 7 is Sunday), `Month`; a missing key matches anything. Checked at the start of each minute. |
| `WatchPaths` | Start when a path changes, or appears (a missing path is looked for every 5 s) |
| `QueueDirectories` | Start while a directory has entries; started again on exit until it's empty |
| `Sockets` | See below |

Every job also gets `XPC_SERVICE_NAME=<Label>` (as launchd sets it), plus `USER`,
`LOGNAME` and `HOME` when it has a `UserName`. Jobs start in their own session with
default signal handling, and no file descriptors are inherited except 0–2 and the
job's own sockets.

## Domains

As in launchd, jobs and Mach service names live in domains:

| Domain | Jobs | Created |
|---|---|---|
| `system` | LaunchDaemons | At boot |
| `user/<uid>` (also addressed as `gui/<uid>`) | LaunchAgents, run as the user | On first request (below) |

A process's bootstrap port names its domain, and children inherit it. A look-up
searches the caller's domain, then the system domain, so a user's processes see
the user's agents and every system service. The system domain's processes don't
see agents. A check-in registers in the caller's own domain. A user domain may
declare a name that the system domain also has, and its own processes then get
the user's.

**Entering a user domain.** A login does what it does on macOS: `/etc/pam.d/login` and
`su` (for `su -l`) run Apple's `pam_launchd` (pam_modules, built from source).
It climbs to the system domain with `bootstrap_parent` (root only), asks for the
user's domain port with `bootstrap_look_up_per_user(…, NULL, uid, …)` and makes it
the task's bootstrap port. `launchctl asuser <uid> <command>` does the same for one
command. Root may ask for any user's domain, a user only for their own. Finch's
libxpc implements these calls, plus `bootstrap_get_root`,
`_vprocmgr_move_subset_to_user`, `_vprocmgr_switch_to_session` and
`_vproc_post_fork_ping`, as control requests to finch-init.

**Creating one.** On the first request, finch-init makes the domain (a new port with its
own request thread in `bootstrapd.c`), then loads the agents in:

| Directory | Contents |
|---|---|
| `/System/Library/Finch/LaunchAgents` | Finch's own agents (and, in the dev VM, test agents) |
| `/Library/LaunchAgents` | Third-party agents, as on macOS |
| `~/Library/LaunchAgents` | The user's own. As launchd requires, each plist must belong to the user or root and be writable only by its owner (others are skipped and logged). Symlinks aren't followed. |

It then starts the RunAtLoad and KeepAlive agents. Agents run as the domain's user
(its primary group and `getgrouplist` groups), with `USER`, `LOGNAME` and `HOME`, and
with the domain's port as their bootstrap port.

**Session types.** On macOS, `user/<uid>` loads only agents limited to the
`Background` session, and the Aqua (GUI) login's `gui/<uid>` domain loads the rest,
since `Aqua` is the default. Finch has no GUI login yet, so a user's one domain stands
in for both. It loads agents with no `LimitLoadToSessionType` or with `Aqua` or
`Background`. `LoginWindow`, `StandardIO` and `System` agents aren't loaded.
`launchctl managername` reports `Background`. This changes when Phase 2 brings a
graphical login.

**Lifetime.** A user domain lasts until `launchctl bootout user/<uid>`, which stops its
agents and destroys its port. The port becomes a dead name in any process still holding
it, so its look-ups fail. A later request creates the domain afresh. Shutdown stops
agents along with daemons.

## Sockets

Each `Sockets` entry is a dictionary (or an array of them) of launchd's `Sock*` keys:
`SockPathName` and `SockPathMode` for a Unix socket, or `SockNodeName`,
`SockServiceName` and `SockFamily` (`IPv4`, `IPv6`) for internet sockets, with
`SockType` `stream` (default), `dgram` or `seqpacket`. finch-init creates and binds
them (and listens, for stream sockets) when the job loads, and starts the job when
one is ready to read. Active sockets (`SockPassive = false`) and Bonjour aren't
supported.

The job inherits its sockets at the same descriptor numbers. It finds them as
launchd jobs do: `launch_activate_socket(name, &fds, &count)`, or the `Sockets`
dictionary of `launch_msg(LAUNCH_KEY_CHECKIN)`'s reply (`{name: [fd]}`). Finch's
libxpc gets both from finch-init's `checkin` request, which describes the caller's
job. While the job runs, finch-init stops watching its sockets; it watches them again
when the job exits. Unloading the job closes them and removes Unix socket files.

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

## launchctl

Apple's `launchctl` is closed and speaks launchd's private protocol. Finch ships its own
(`userland/launchctl`, installed as `/bin/launchctl`), which accepts the commonly used
macOS syntax:

| Command | Effect |
|---|---|
| `launchctl list [label]` | `PID  Status  Label` table, or one job as a dictionary. Status is the last exit code, or −signal. |
| `launchctl print system`, `print system/<label>` | Job details: state, runs, last exit, settings, and each Mach service (active, or waiting with N queued messages) |
| `launchctl start` / `stop <label>` | Start if not running / send SIGTERM. A KeepAlive job comes back. |
| `launchctl kickstart [-k] system/<label>` | Start now, ignoring the throttle. With `-k`, SIGKILL a running instance first. |
| `launchctl kill <signal> system/<label>` | Send a signal (name or number) |
| `launchctl load` / `bootstrap system <plist>…` | Load jobs at runtime (RunAtLoad and KeepAlive apply) |
| `launchctl unload <plist>…`, `bootout system/<label>` | SIGTERM the job, remove it and release its service names |

| `launchctl print user/<uid>`, `print user/<uid>/<label>` | The same for a user domain (`gui/<uid>` is accepted for `user/<uid>`) |
| `launchctl bootstrap user/<uid> <plist>…` | Load agents into a user's domain, creating it if needed |
| `launchctl bootout user/<uid>/<label>`, `bootout user/<uid>` | Remove one agent, or the whole domain |
| `launchctl asuser <uid> <command>…` | Run a command in the user's domain |
| `launchctl manageruid`, `managerpid`, `managername` | The caller's domain: its uid (0 for system), finch-init's pid, `System` or `Background` |

Commands without a domain (`list`, `start`, `stop`, `load`, `unload`) act on the
caller's domain. Requests are xpc_pipe routines on the bootstrap port carrying an `op`
key (and a `domain` when one is named), with errno results. Anyone may read the system
domain, and a user may read their own. Changes need an effective uid of 0, taken from the
request's audit token, except that a user may change their own domain.

## Shutdown and reboot

`reboot`, `halt` and `shutdown` (system_cmds, built from source) end in `reboot3(howto)`,
which on macOS hands the job to launchd. Finch's libxpc sends it to finch-init as a
root-only control request. finch-init accepts, then on its queue:

1. stops starting jobs (no KeepAlive restarts, no launch on demand) and stops respawning
   the console shell;
2. sends every running job SIGTERM, and waits until they exit or 20 s pass (launchd's
   default `ExitTimeOut`), then SIGKILLs the rest;
3. sends every other process SIGTERM (`kill(-1)`), waits up to 5 s, then SIGKILL;
4. calls `sync()` unless `RB_NOSYNC`, then `reboot(howto)`. The kernel then disables
   kexts, syncs and unmounts everything.

In the VM the whole sequence completes ("CPU halted" / "MACH Reboot"). The emulated
machine has no SMC, so halt's final power-off times out (a platform panic). After a
reboot the emulator doesn't start again. Both work on real hardware.

finch-init opens `/dev/console` afresh for every log line. When the console shell (the
session leader) exits, the kernel revokes the terminal, including descriptors PID 1
holds. Before this fix, finch-init's messages silently stopped after the first shell
exit.

## Tests

- `userland/libxpc/tests/bootstrap-test.c` (host, ASan/UBSan) covers:
  - The registry rules.
  - Declared services with a fake job manager: visible before launch, demand on the first
    message, check-in only by the job, the triggering message still queued after
    check-in, the right returning with unread messages when the job's right dies, and
    clients' send rights staying valid throughout.
- `bootstrap-test` also covers domains: look-ups falling back to the parent, check-ins
  staying in the caller's domain, shadowing, `bootstrap_parent` (refused to non-root
  in a user domain), `bootstrap_look_up_per_user`, the control hook's domain, and
  destruction.
- Per-user agents (VM; the dev image has a test user, `finchtest`, uid 501, whose home is
  under `/Users`, a link into a tmpfs). As root, copy
  `/usr/local/share/finch-tests/org.finch.test.homeagent.plist` into
  `~finchtest/Library/LaunchAgents`, plus a group-writable copy, then
  `su -l finchtest -c 'finch-xpc-service-test useragent'`. pam_launchd moves su into
  user/501. The domain is created with the system test agent and the home agent; the
  group-writable copy is refused. `org.finch.test.agent` starts on demand as uid 501,
  and system services stay visible. The home agent (RunAtLoad) records that it ran as
  `finchtest`. From the system domain, `print system/org.finch.test.agent` fails and
  `print gui/501/org.finch.test.agent` works. As the user, changing the system domain
  is refused and booting out the user's own agent works. `launchctl asuser` and
  `bootout user/<uid>` were also checked.
- `finch-xpc-service-test ondemand` (VM): a client messages `org.finch.test.ondemand`.
  finch-init launches the daemon, which answers and then exits on request. The same
  client connection then relaunches it with a new pid.
- `launchctl` (VM): list, print, kill, kickstart (and `-k` on notifyd, after which
  notifications still flow through the same service port), unload and load (the name
  disappears and comes back). `org.finch.test.unprivileged` runs launchctl as `nobody`:
  reads succeed and changes are refused.
- `org.finch.test.keepalive` (VM): a job running as `nobody` with
  `KeepAlive={SuccessfulExit=false}` fails twice, is restarted, then succeeds and stays
  stopped.

## Not yet

- A graphical login session (`gui/<uid>` as its own domain, Aqua-only agents), and
  `login/<asid>` and `pid/<pid>` domains.
- Domains created on a user's first process even without pam_launchd. On macOS,
  launchd also creates them for any process of that uid.
- These keys: `LaunchEvents`, `KeepAlive` conditions other than `SuccessfulExit`,
  `ExitTimeOut`, `ResetAtClose`, `HideUntilCheckIn`, `Nice`, `ProcessType`, resource
  limits.
