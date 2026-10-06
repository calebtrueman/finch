# XPC Mach protocol (as spoken by macOS 26.4)

Recorded from Apple's libxpc on a real Mac with `tools/xpc-capture/{mach,server}-capture.c`.
The raw dumps are in `userland/libxpc/tests/fixtures/apple-25E253-mach.txt`. Finch's
libxpc speaks this protocol, so Finch processes and Apple's daemons can talk to each
other.

## Payload

Every XPC message body is the serialization from `serialize.c` with magic **`CPX@`**
(`43 50 58 40`) instead of the standalone serialization magic `B7\x13B` (`0x42133742`).
Both use version 5. Out-of-band objects (file descriptors and other port-carrying types)
are Mach port descriptors, in order. The payload then holds only their type word
(e.g. `0x0000b000` for an fd). File descriptors travel as fileports (`MOVE_SEND`).

## Message IDs

| msgh_id | Meaning | Reply port |
|---|---|---|
| `0x10000000` | Message (client→server or server→client), pipe simpleroutine | none |
| `0x10000000` | Message expecting a reply | send-once right in `msgh_local_port` |
| `0x20000000` | Reply, sent to that send-once right | — |
| `0x40000000` | Pipe routine (request/response over `xpc_pipe`) | send-once |
| `0x77303074` | `'w00t'`: connection handshake | — |

## Connection setup

1. The client looks up the service port (bootstrap name or endpoint).
2. The client sends **`w00t`** to it: a complex message, no payload, two port descriptors:
   - `[0]` **MOVE_RECEIVE** of a new port *S*. This is the server's end of this
     connection: the client keeps a send right and sends every message to *S*.
   - `[1]` **MAKE_SEND** to the client's own receive port *C*. The server sends
     unsolicited messages there.
3. Messages flow: client→*S* (`0x10000000`), server→*C* (`0x10000000`), and replies go to
   per-request send-once ports (`0x20000000`).

Apple's server accepts this exact handshake from a non-libxpc client
(`server-capture.c`), which confirms the client side of the protocol is complete for
basic messaging.

## Bootstrap (launchd's registry protocol)

Captured from Apple's libxpc with `tools/xpc-capture/bootstrap-capture.c` (macOS 26.4.1).
`bootstrap_look_up`, `bootstrap_look_up2` and `bootstrap_check_in` are xpc_pipe routines
sent to the task's bootstrap port. They use **`msgh_id = 0x40000000 | routine`** and a
send-once reply right. The request is a complex message whose only descriptor is the
`domain-port` send right.

| Routine | id | Request dictionary |
|---|---|---|
| check_in | 206 (`0x400000ce`) | `handle: uint64 0`, `flags: uint64`, `name: string`, `type: uint64 7`, `domain-port: mach_send` |
| look_up / look_up2 | 207 (`0x400000cf`) | the same fields, plus `instance: uuid (zero)` and `targetpid: int64` |

Type 7 means "Mach service". The reply (`msgh_id 0x20000000`) carries `error` (int64, 0 on
success). On success it also carries `port`: a `mach_send` for look_up, or a
`mach_recv` (the moved receive right) for check_in. launchd also sends `req_pid` and
`rec_execcnt`, and finch-init does the same.

Differences from Apple:

- Apple's client only accepts replies from PID 1. Finch's client doesn't check, because a
  parent that controls a child's bootstrap port already controls the child.
- finch-init puts Mach bootstrap codes in `error` (1102 unknown service, 1103 service
  active, …). Finch's client also maps errno-style codes in case it ever talks to a
  launchd-like server.
- Apple's `xpc_pipe_receive` rejects routine message ids, so a bootstrap server has to
  use Finch's libxpc. finch-init reads the routine number with the Finch SPI
  `finch_xpc_pipe_request_routine()`.
- **libxpc owns `bootstrap_port`.** libsystem_kernel only declares it. libxpc's
  initializer, and its atfork-child hook (a forked child has a fresh port space), fetch
  it with `task_get_special_port(TASK_BOOTSTRAP_PORT)`.
