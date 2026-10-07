# Metric checks and packet layout

`tests/metric-compare.c` checks labels, label size limits, dimensions, all three
number types, all three stored-statistics modes, histogram buckets, reset,
unit and scale changes, and object release. It also lets each library update
objects made by the other library. The 8,884 comparisons passed on the host.

The send helper receives the log object, number type (0 signed integer,
1 double, 2 unsigned integer), image address, caller address, reported value,
and an owned-by-caller packet that stays valid until the helper returns.

The packet starts with the metric's 16 bytes at offset 40: kind, number type,
statistics mode, unit, scale, bucket count, two reserved bytes, 32-bit bucket
width, option byte, and three reserved bytes. Then come 8, 48, or 88 bytes of
stored values for modes 0, 1, or 2; eight bytes for each histogram bucket; the
flattened metric label; the group dimensions; and the metric dimensions.
Each flattened string starts with a 16-bit length. Static strings may instead
use type 1 or 2 in the high four bits and a four- or six-byte image offset.

The native send path uses identifier namespace 8. Its outer data includes the
caller address, subsystem ID, and reported value before this packet. The
number type selects the record type. The native flatten-and-send flags are
`0x20040000 | (errno & 0xffff)`, with format `%s` and this packet in the extra
data record. `finch_trace_metric_send` owns that outer transport step.

The standalone comparison uses a capture helper for the send call. It proves
the stored numbers and labels, not receipt by logd. The main trace checks must
verify the final outer packet and delivery separately.
