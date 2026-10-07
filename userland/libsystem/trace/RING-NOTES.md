# Ring checks

`tests/ring-compare.c` compares the ring and resource calls with the installed
system library. It checks segment counts and sizes from 1 through 32, in powers
of two, with 50 writes per case. It checks the stored bytes, wraparound, lost
messages, read positions, short read buffers, early callback stops, and calls
that mix the two libraries. It also checks duplicate resource IDs, bad headers,
resource iteration, and memory size names.

The comparison passed on the test host. The code follows the host's observed
write behavior when a message has several pieces and crosses the ring's end.
Later pieces can overwrite the start of the second region; this behavior is
covered by the test.

These checks cover memory shared by callers in one process. They do not prove
that a separate logging service receives messages. The logd connection,
shared-memory handoff, reconnect behavior, and concurrent readers and writers
need their own checks. `ring.c` does not replace that connection with a private
in-process buffer.
