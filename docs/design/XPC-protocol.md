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
