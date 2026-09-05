# Prototypes

Throwaway C used to validate the walk before any Swift was written. Kept because
they encode two things that are expensive to rediscover:

1. **The exact `getattrlistbulk` attribute decode order.** Attributes come back
   in ascending bit order, except `ATTR_CMN_RETURNED_ATTRS` which is hoisted to
   the front. You MUST consult the returned-attrs mask per entry — the `fileattr`
   group is absent for directories, and blindly consuming those bytes desynchronises
   the whole buffer.

2. **The path-truncation cycle bug.** `pwalk.c` originally used a 256-byte path
   buffer. Deep paths truncate, and a truncated path can resolve to an *ancestor
   directory*, which makes the walk loop forever. Detect truncation via
   `snprintf`'s return value and skip the entry. Never push a truncated path.

Measured on the development machine (M-series 4P+6E, macOS 26.5, APFS):

| target | entries | j=1 | j=8 |
|---|---:|---:|---:|
| `/Applications/Xcode.app` | 146,979 | 0.70 s | — |
| `$HOME` | 1,965,464 | 30.38 s | 6.29 s |

`$HOME` also yielded: 251.4 GiB physical vs 770.0 GiB logical, 132,390 dataless
placeholders, 74,701 hard-linked files, max depth 25, avg filename 22.8 bytes.
